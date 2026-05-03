// Read-only fraud analysis. Runs without sharing for org-wide pattern detection.
public without sharing class WC_FraudPatternCheck {

    private static final Integer DEALER_VOLUME_HIGH = 40;
    private static final Integer DEALER_VOLUME_MEDIUM = 15;
    private static final Integer VEHICLE_REPEAT_FLAG = 3;
    private static final Integer EXPIRY_PROXIMITY_DAYS = 30;

    public class FraudRequest {
        @InvocableVariable(required=true label='Scope' description='REQUIRED. Must be exactly one of: "system" (org-wide pattern scan), "dealer" (specific dealer fraud check), "vehicle" (specific VIN check), "claim" (specific claim fraud signals). Pick "system" for "check for fraud", "any suspicious patterns", "system-wide check". Pick "dealer" when user names a dealer like "investigate Pune Electra". Pick "vehicle" when user gives a VIN. Pick "claim" when user names a specific claim. NEVER omit this — the action will fail.')
        public String scope;

        @InvocableVariable(label='Scope Id' description='Optional Salesforce Id (15/18-char) — Account Id for dealer scope, Vehicle Id for vehicle scope, Claim Id for claim scope. Use Dealer Name / VIN / Claim Number instead when user gives a string identifier.')
        public String scopeId;

        @InvocableVariable(label='Dealer Name' description='Dealer Account.Name when scope="dealer". Examples: "Pune Electra Service Center", "Bangalore Electra Motors", "Mumbai Electra Service Center". Pass the dealer name string exactly as the user said it.')
        public String dealerName;

        @InvocableVariable(label='VIN' description='17-character Vehicle Identification Number when scope="vehicle". Example: 1ELEC2024BOLT003.')
        public String vin;

        @InvocableVariable(label='Claim Number' description='Claim Name string when scope="claim". Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007.')
        public String claimNumber;

        @InvocableVariable(label='Days Back' description='Lookback window in days. Default 30, max 180. Examples: pass 7 for "last week", 30 for "last month", 90 for "last quarter", 180 for "last 6 months".')
        public Integer daysBack;

        @InvocableVariable(label='Min Amount' description='Optional dollar threshold when scope="system" — flag only claims with EstimatedAmount at or above this. Examples: 5000 for "claims over $5000", 10000 for "high-value claims".')
        public Decimal minAmount;

        @InvocableVariable(label='Min Risk Score' description='Optional risk score threshold when scope="system" — flag only claims with Risk_Score__c at or above this (0-100 scale). Examples: 70 for "high-risk", 80 for "critical risk".')
        public Decimal minRiskScore;
    }

    public class FraudResponse {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text fraud pattern report. Present verbatim.')
        public String message;

        // Internal-only.
        public String overallRisk;
        public String flags;
        public Integer totalClaimsAnalyzed;
        public Integer flagCount;
        public String recommendation;
        public String errorMessage;
    }

    @InvocableMethod(label='Fraud Pattern Check' description='Electra Cars warranty anomaly hints')
    public static List<FraudResponse> analyze(List<FraudRequest> requests) {
        List<FraudResponse> results = new List<FraudResponse>();
        if (requests == null) {
            return results;
        }
        for (FraudRequest req : requests) {
            FraudResponse fr = new FraudResponse();
            Integer days = (req.daysBack != null && req.daysBack > 0) ? Math.min(req.daysBack, 180) : 30;
            Datetime cutoff = Datetime.now().addDays(-days);
            String sc = String.isBlank(req.scope) ? '' : req.scope.trim().toLowerCase();

            try {
                if (sc == 'system') {
                    analyzeSystem(req, cutoff, days, fr);
                    results.add(fr);
                    continue;
                }
                Id resolvedId = resolveId(sc, req);
                if (resolvedId == null) {
                    fr.errorMessage = 'Could not resolve a Scope Id. Provide either Scope Id, Dealer Name, VIN, or Claim Number.';
                    results.add(fr);
                    continue;
                }
                if (sc == 'claim') {
                    analyzeClaim(resolvedId, cutoff, days, fr);
                } else if (sc == 'dealer') {
                    analyzeDealer(resolvedId, cutoff, days, fr);
                } else if (sc == 'vehicle') {
                    analyzeVehicle(resolvedId, cutoff, fr);
                } else {
                    fr.errorMessage = 'Use claim, dealer, vehicle, or system.';
                }
            } catch (Exception e) {
                fr.errorMessage = 'Fraud analysis failed: ' + e.getMessage();
            }
            // Build the final formatted message for any analysis path.
            fr.message = formatFraudMessage(req, sc, fr);
            results.add(fr);
        }
        return results;
    }

    private static String formatFraudMessage(FraudRequest req, String sc, FraudResponse fr) {
        if (fr.errorMessage != null) {
            return '⚠️ ' + fr.errorMessage;
        }
        String riskIcon = '⚪';
        if (fr.overallRisk == 'High') { riskIcon = '🔴'; }
        else if (fr.overallRisk == 'Medium') { riskIcon = '🟠'; }
        else if (fr.overallRisk == 'Low') { riskIcon = '🟢'; }

        String scopeLabel = sc.toUpperCase();
        if (sc == 'dealer' && req.dealerName != null) { scopeLabel = 'DEALER: ' + req.dealerName; }
        else if (sc == 'vehicle' && req.vin != null) { scopeLabel = 'VEHICLE: ' + req.vin; }
        else if (sc == 'claim' && req.claimNumber != null) { scopeLabel = 'CLAIM: ' + req.claimNumber; }

        List<String> ml = new List<String>();
        ml.add('🔍 Fraud Pattern Check — ' + scopeLabel);
        ml.add('━━━━━━━━━━━━━━━━━━━━━━━');
        ml.add('Overall Risk: ' + riskIcon + ' ' + (fr.overallRisk != null ? fr.overallRisk : 'Unknown'));
        if (fr.flagCount != null) { ml.add('Flag Count: ' + fr.flagCount); }
        if (fr.totalClaimsAnalyzed != null) { ml.add('Claims Analyzed: ' + fr.totalClaimsAnalyzed); }
        if (fr.flags != null && fr.flags != '') {
            ml.add('');
            ml.add('Flags:');
            ml.add(fr.flags);
        }
        if (fr.recommendation != null) {
            ml.add('');
            ml.add('Recommendation: ' + fr.recommendation);
        }
        return String.join(ml, '\n');
    }

    private static Id resolveId(String sc, FraudRequest req) {
        if (String.isNotBlank(req.scopeId)) {
            try { return Id.valueOf(req.scopeId.trim()); } catch (Exception e) { /* fall through */ }
        }
        if (sc == 'dealer' && String.isNotBlank(req.dealerName)) {
            List<Account> dealers = [SELECT Id FROM Account WHERE Name = :req.dealerName.trim() LIMIT 1];
            if (!dealers.isEmpty()) return dealers[0].Id;
        }
        if (sc == 'vehicle' && String.isNotBlank(req.vin)) {
            List<Vehicle> vehicles = [SELECT Id FROM Vehicle WHERE VehicleIdentificationNumber = :req.vin.trim() LIMIT 1];
            if (!vehicles.isEmpty()) return vehicles[0].Id;
        }
        if (sc == 'claim' && String.isNotBlank(req.claimNumber)) {
            List<Claim> claims = [SELECT Id FROM Claim WHERE Name = :req.claimNumber.trim() LIMIT 1];
            if (!claims.isEmpty()) return claims[0].Id;
        }
        return null;
    }

    private static void analyzeSystem(FraudRequest req, Datetime cutoff, Integer days, FraudResponse fr) {
        Decimal minAmt = req.minAmount;
        Decimal minRisk = req.minRiskScore;
        Integer cnt = [SELECT COUNT() FROM Claim WHERE CreatedDate >= :cutoff];
        fr.totalClaimsAnalyzed = cnt;

        List<String> flagLines = new List<String>();
        Integer flagCount = 0;

        // Rule 1 — Duplicate VIN within window
        AggregateResult[] dupVin = [
            SELECT Vehicle.VehicleIdentificationNumber vin, COUNT(Id) ct
            FROM ClaimItem
            WHERE Claim.CreatedDate >= :cutoff AND VehicleId != null
            GROUP BY Vehicle.VehicleIdentificationNumber
            HAVING COUNT(Id) >= 2
            ORDER BY COUNT(Id) DESC
            LIMIT 5
        ];
        for (AggregateResult ar : dupVin) {
            flagLines.add('[Duplicate VIN] ' + (String) ar.get('vin') + ' appears on ' + ar.get('ct') + ' claims in last ' + days + 'd.');
            flagCount++;
        }

        // Rule 2 — Dealer volume spike
        AggregateResult[] dealerVol = [
            SELECT Account.Name dealer, COUNT(Id) ct
            FROM Claim
            WHERE CreatedDate >= :cutoff AND AccountId != null
            GROUP BY Account.Name
            HAVING COUNT(Id) > :DEALER_VOLUME_HIGH
            ORDER BY COUNT(Id) DESC
            LIMIT 5
        ];
        for (AggregateResult ar : dealerVol) {
            flagLines.add('[Dealer Volume High] ' + (String) ar.get('dealer') + ' filed ' + ar.get('ct') + ' claims (>' + DEALER_VOLUME_HIGH + ' threshold).');
            flagCount++;
        }

        // Rule 3 — Warranty expiring soon (claims filed within 30 days of warranty end)
        Date soon = Date.today().addDays(EXPIRY_PROXIMITY_DAYS);
        Set<Id> assetIdsExpiring = new Set<Id>();
        for (AssetWarranty aw : [
            SELECT AssetId FROM AssetWarranty
            WHERE EndDate >= TODAY AND EndDate <= :soon
            LIMIT 200
        ]) {
            if (aw.AssetId != null) { assetIdsExpiring.add(aw.AssetId); }
        }
        if (!assetIdsExpiring.isEmpty()) {
            Set<Id> vehIds = new Set<Id>();
            for (Vehicle v : [SELECT Id FROM Vehicle WHERE AssetId IN :assetIdsExpiring]) {
                vehIds.add(v.Id);
            }
            if (!vehIds.isEmpty()) {
                Integer expClaims = [
                    SELECT COUNT() FROM ClaimItem
                    WHERE VehicleId IN :vehIds AND Claim.CreatedDate >= :cutoff
                ];
                if (expClaims > 0) {
                    flagLines.add('[Warranty Expiry Proximity] ' + expClaims + ' claim line(s) filed against vehicles whose warranty expires within ' + EXPIRY_PROXIMITY_DAYS + ' days.');
                    flagCount++;
                }
            }
        }

        // Rule 4 — High-amount AND high-risk outliers
        if (minAmt != null || minRisk != null) {
            String soql = 'SELECT Id, Name, EstimatedAmount, Risk_Score__c, Account.Name FROM Claim WHERE CreatedDate >= :cutoff';
            if (minAmt != null) { soql += ' AND EstimatedAmount >= :minAmt'; }
            if (minRisk != null) { soql += ' AND Risk_Score__c >= :minRisk'; }
            soql += ' ORDER BY Risk_Score__c DESC NULLS LAST, EstimatedAmount DESC LIMIT 10';
            List<Claim> outliers = Database.query(soql);
            for (Claim c : outliers) {
                flagLines.add('[High-Value High-Risk] ' + c.Name + ' $' + (c.EstimatedAmount != null ? c.EstimatedAmount.setScale(0).toPlainString() : '0') + ' Risk ' + (c.Risk_Score__c != null ? c.Risk_Score__c.intValue() : 0) + ' (' + (c.Account != null ? c.Account.Name : 'Unknown') + ').');
                flagCount++;
            }
        }

        fr.flagCount = flagCount;
        fr.flags = flagLines.isEmpty() ? 'No anomaly patterns detected in last ' + days + ' days.' : String.join(flagLines, '\n');
        fr.overallRisk = flagCount >= 5 ? 'High' : (flagCount >= 2 ? 'Medium' : 'Low');
        fr.recommendation = flagCount == 0
            ? 'No system-wide flags. Continue normal queue review.'
            : 'Review flagged dealers and high-risk claims; not an accusation — investigate further.';
    }

    private static void analyzeClaim(Id claimId, Datetime cutoff, Integer days, FraudResponse fr) {
        Claim c = [
            SELECT Id, AccountId, Name, Summary, EstimatedAmount, Risk_Score__c
            FROM Claim WHERE Id = :claimId LIMIT 1
        ];
        List<String> flagLines = new List<String>();
        Integer flagCount = 0;

        Set<Id> vehicleIds = new Set<Id>();
        for (ClaimItem ci : [SELECT VehicleId FROM ClaimItem WHERE ClaimId = :claimId AND VehicleId != null]) {
            vehicleIds.add(ci.VehicleId);
        }
        if (!vehicleIds.isEmpty()) {
            Integer relatedItems = [
                SELECT COUNT() FROM ClaimItem WHERE VehicleId IN :vehicleIds AND ClaimId != :claimId
            ];
            if (relatedItems >= VEHICLE_REPEAT_FLAG) {
                flagLines.add('[Vehicle Repeat] Same vehicle(s) appear on ' + relatedItems + ' other claim line(s) — investigate overlap.');
                flagCount++;
            }
            for (Id vid : vehicleIds) {
                List<AssetWarranty> aw = [
                    SELECT EndDate FROM AssetWarranty
                    WHERE AssetId IN (SELECT AssetId FROM Vehicle WHERE Id = :vid)
                    ORDER BY EndDate DESC LIMIT 1
                ];
                if (!aw.isEmpty() && aw[0].EndDate != null
                    && aw[0].EndDate >= Date.today()
                    && aw[0].EndDate <= Date.today().addDays(EXPIRY_PROXIMITY_DAYS)) {
                    flagLines.add('[Warranty Expiry Proximity] Vehicle warranty ends ' + aw[0].EndDate + ' (within ' + EXPIRY_PROXIMITY_DAYS + ' days).');
                    flagCount++;
                    break;
                }
            }
        }
        if (c.AccountId != null) {
            Integer dealerVol = [
                SELECT COUNT() FROM Claim
                WHERE AccountId = :c.AccountId AND CreatedDate >= :cutoff
            ];
            flagLines.add('[Info] Dealer claim volume (' + days + 'd): ' + dealerVol);
            if (dealerVol > DEALER_VOLUME_HIGH) { flagCount++; }
            fr.totalClaimsAnalyzed = dealerVol;
        }
        if (c.EstimatedAmount != null && c.EstimatedAmount > 5000 && c.Risk_Score__c != null && c.Risk_Score__c >= 70) {
            flagLines.add('[High-Value High-Risk] $' + c.EstimatedAmount.setScale(0).toPlainString() + ' with risk ' + c.Risk_Score__c.intValue() + '.');
            flagCount++;
        }

        fr.flagCount = flagCount;
        fr.flags = flagLines.isEmpty() ? 'No fraud flags on this claim.' : String.join(flagLines, '\n');
        fr.overallRisk = flagCount >= 3 ? 'High' : (flagCount >= 1 ? 'Medium' : 'Low');
        if (fr.totalClaimsAnalyzed == null) { fr.totalClaimsAnalyzed = 1; }
        fr.recommendation = flagCount == 0
            ? 'No strong anomaly flags for this claim.'
            : 'Patterns suggest deeper review — not an accusation, request supporting documentation.';
    }

    private static void analyzeDealer(Id accountId, Datetime cutoff, Integer days, FraudResponse fr) {
        Integer vol = [SELECT COUNT() FROM Claim WHERE AccountId = :accountId AND CreatedDate >= :cutoff];
        Integer denied = [SELECT COUNT() FROM Claim WHERE AccountId = :accountId AND CreatedDate >= :cutoff AND Status = 'Denied'];
        AggregateResult[] dupVin = [
            SELECT Vehicle.VehicleIdentificationNumber vin, COUNT(Id) ct
            FROM ClaimItem
            WHERE Claim.AccountId = :accountId AND Claim.CreatedDate >= :cutoff AND VehicleId != null
            GROUP BY Vehicle.VehicleIdentificationNumber
            HAVING COUNT(Id) >= 2
            ORDER BY COUNT(Id) DESC
            LIMIT 5
        ];

        List<String> flagLines = new List<String>();
        Integer flagCount = 0;
        flagLines.add('[Volume] ' + vol + ' claims in last ' + days + 'd; ' + denied + ' previously denied.');
        if (vol > DEALER_VOLUME_HIGH) { flagCount++; flagLines.add('[Dealer Volume High] Above ' + DEALER_VOLUME_HIGH + ' threshold.'); }
        for (AggregateResult ar : dupVin) {
            flagLines.add('[Duplicate VIN] ' + (String) ar.get('vin') + ' filed ' + ar.get('ct') + ' times by this dealer.');
            flagCount++;
        }
        if (vol > 0 && denied * 100 / vol >= 30) {
            flagLines.add('[Denial Rate] ' + (denied * 100 / vol) + '% of claims denied — high prior-rejection rate.');
            flagCount++;
        }

        fr.totalClaimsAnalyzed = vol;
        fr.flagCount = flagCount;
        fr.flags = String.join(flagLines, '\n');
        fr.overallRisk = vol > DEALER_VOLUME_HIGH || flagCount >= 2 ? 'High'
            : (vol > DEALER_VOLUME_MEDIUM || flagCount >= 1 ? 'Medium' : 'Low');
        fr.recommendation = 'Compare volume vs peer Electra Cars dealers; investigate any duplicate-VIN flags before approving new claims from this dealer.';
    }

    private static void analyzeVehicle(Id vehicleId, Datetime cutoff, FraudResponse fr) {
        Set<Id> cids = new Set<Id>();
        for (ClaimItem ci : [SELECT ClaimId FROM ClaimItem WHERE VehicleId = :vehicleId]) {
            cids.add(ci.ClaimId);
        }
        Integer total = 0;
        Integer recent = 0;
        if (!cids.isEmpty()) {
            total = [SELECT COUNT() FROM Claim WHERE Id IN :cids];
            recent = [SELECT COUNT() FROM Claim WHERE Id IN :cids AND CreatedDate >= :cutoff];
        }
        List<String> flagLines = new List<String>();
        Integer flagCount = 0;
        flagLines.add('[Vehicle History] ' + total + ' total claims, ' + recent + ' in window.');
        if (recent >= VEHICLE_REPEAT_FLAG) {
            flagLines.add('[Vehicle Repeat] ' + recent + ' claims in window — investigate part repeat-failure.');
            flagCount++;
        }
        Vehicle v = [SELECT AssetId FROM Vehicle WHERE Id = :vehicleId LIMIT 1];
        if (v.AssetId != null) {
            List<AssetWarranty> aw = [
                SELECT EndDate FROM AssetWarranty WHERE AssetId = :v.AssetId
                ORDER BY EndDate DESC LIMIT 1
            ];
            if (!aw.isEmpty() && aw[0].EndDate != null
                && aw[0].EndDate >= Date.today()
                && aw[0].EndDate <= Date.today().addDays(EXPIRY_PROXIMITY_DAYS)) {
                flagLines.add('[Warranty Expiry Proximity] Warranty ends ' + aw[0].EndDate + '.');
                flagCount++;
            }
        }
        fr.totalClaimsAnalyzed = recent;
        fr.flagCount = flagCount;
        fr.flags = String.join(flagLines, '\n');
        fr.overallRisk = flagCount >= 2 ? 'High' : (flagCount >= 1 ? 'Medium' : 'Low');
        fr.recommendation = 'Review part repeat failures and warranty timing.';
    }
}