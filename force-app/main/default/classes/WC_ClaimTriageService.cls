public with sharing class WC_ClaimTriageService {
    private static final String REC_APPROVE = 'Auto-Approve';
    private static final String REC_REVIEW = 'Needs Review';
    private static final String REC_DENY = 'Auto-Deny';

    public class Input {
        @InvocableVariable(required = true label = 'Claim Id' description = 'Salesforce ID of the Claim to triage')
        public Id claimId;
    }

    public class Output {
        @InvocableVariable(label = 'Risk Score' description = 'Calculated risk score from 0 (low risk) to 100 (high risk); -1 on failure')
        public Decimal riskScore;
        @InvocableVariable(label = 'Recommendation' description = 'Triage decision: Auto-Approve, Needs Review, or Auto-Deny')
        public String recommendation;
        @InvocableVariable(label = 'Triage Notes' description = 'Detailed reasoning for the triage decision')
        public String triageNotes;
        @InvocableVariable(label = 'Factors' description = 'Comma-separated list of factors that contributed to the score')
        public String factors;
        @InvocableVariable(label = 'Message' description = 'Human-readable summary of the triage result')
        public String message;
    }

    @InvocableMethod(
        label = 'Triage Warranty Claim'
        description = 'Analyzes a warranty claim and calculates a risk score (0-100). Returns triage recommendation: Auto-Approve, Needs Review, or Auto-Deny with detailed reasoning.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> ordered = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return ordered;
        }
        try {
            Map<String, WC_Triage_Rule__mdt> rules = loadRules();
            Decimal approveMax = decRule(rules, 'Routing_Thresholds', 'Auto_Approve_Max__c', 20);
            Decimal denyMin = decRule(rules, 'Routing_Thresholds', 'Auto_Deny_Min__c', 80);
            Decimal highAmtThreshold = decRule(rules, 'High_Value_Claim', 'Threshold_Value__c', 400000);
            Decimal dealerVolThreshold = decRule(rules, 'High_Volume_Dealer', 'Threshold_Value__c', 10);

            Set<Id> claimIds = new Set<Id>();
            for (Input inRow : inputs) {
                if (inRow != null && inRow.claimId != null) {
                    claimIds.add(inRow.claimId);
                }
            }

            Map<Id, Claim> claimById = claimIds.isEmpty()
                ? new Map<Id, Claim>()
                : new Map<Id, Claim>(
                      [
                          SELECT
                              Id,
                              Name,
                              Status,
                              AccountId,
                              InsuredAssetId,
                              EstimatedAmount,
                              TotalClaimedAmount,
                              Summary,
                              Severity,
                              InitiationDate,
                              MileageAtClaim__c,
                              DiagnosticTroubleCode__c,
                              Channel__c,
                              Vehicle_VIN__c,
                              FailureDescription__c
                          FROM Claim
                          WHERE Id IN :claimIds
                      ]
                  );

            Map<Id, List<ClaimItem>> itemsByClaim = new Map<Id, List<ClaimItem>>();
            Set<Id> productIds = new Set<Id>();
            if (!claimIds.isEmpty()) {
                for (ClaimItem ci : [
                    SELECT Id, ClaimId, ProductId, AssetId, Product.Name, Product.ProductCode, EstimatedAmount__c
                    FROM ClaimItem
                    WHERE ClaimId IN :claimIds
                ]) {
                    if (!itemsByClaim.containsKey(ci.ClaimId)) {
                        itemsByClaim.put(ci.ClaimId, new List<ClaimItem>());
                    }
                    itemsByClaim.get(ci.ClaimId).add(ci);
                    if (ci.ProductId != null) {
                        productIds.add(ci.ProductId);
                    }
                }
            }

            Set<String> claimVins = new Set<String>();
            for (Claim c : claimById.values()) {
                if (String.isNotBlank(c.Vehicle_VIN__c)) {
                    claimVins.add(c.Vehicle_VIN__c);
                }
            }
            Map<String, Id> assetIdByVin = new Map<String, Id>();
            if (!claimVins.isEmpty()) {
                for (Vehicle v : [
                    SELECT AssetId, VehicleIdentificationNumber
                    FROM Vehicle
                    WHERE VehicleIdentificationNumber IN :claimVins AND AssetId != null
                ]) {
                    assetIdByVin.put(v.VehicleIdentificationNumber, v.AssetId);
                }
            }

            Set<Id> assetIds = new Set<Id>();
            Set<Id> dealerIds = new Set<Id>();
            Map<Id, Id> assetIdByClaim = new Map<Id, Id>();
            for (Claim c : claimById.values()) {
                Id effAsset = c.InsuredAssetId;
                if (effAsset == null && itemsByClaim.containsKey(c.Id)) {
                    for (ClaimItem ci : itemsByClaim.get(c.Id)) {
                        if (ci.AssetId != null) {
                            effAsset = ci.AssetId;
                            break;
                        }
                    }
                }
                if (effAsset == null && String.isNotBlank(c.Vehicle_VIN__c)) {
                    effAsset = assetIdByVin.get(c.Vehicle_VIN__c);
                }
                if (effAsset != null) {
                    assetIdByClaim.put(c.Id, effAsset);
                    assetIds.add(effAsset);
                }
                if (c.AccountId != null) {
                    dealerIds.add(c.AccountId);
                }
            }

            Map<Id, Vehicle> vehicleByAssetId = new Map<Id, Vehicle>();
            if (!assetIds.isEmpty()) {
                for (Vehicle v : [
                    SELECT
                        Id,
                        AssetId,
                        VehicleIdentificationNumber,
                        LastOdometerReading,
                        IsRecallOpen,
                        ManufacturedDate,
                        ModelYear,
                        MakeName,
                        ModelName
                    FROM Vehicle
                    WHERE AssetId IN :assetIds
                ]) {
                    vehicleByAssetId.put(v.AssetId, v);
                }
            }

            Map<Id, List<AssetWarranty>> warrantiesByAsset = new Map<Id, List<AssetWarranty>>();
            if (!assetIds.isEmpty()) {
                Date today = Date.today();
                for (AssetWarranty aw : [
                    SELECT Id, AssetId, WarrantyTermId, StartDate, EndDate, WarrantyTerm.UsageCovered, WarrantyTerm.WarrantyTermName
                    FROM AssetWarranty
                    WHERE AssetId IN :assetIds AND StartDate <= :today AND EndDate >= :today
                ]) {
                    if (!warrantiesByAsset.containsKey(aw.AssetId)) {
                        warrantiesByAsset.put(aw.AssetId, new List<AssetWarranty>());
                    }
                    warrantiesByAsset.get(aw.AssetId).add(aw);
                }
            }

            Map<Id, Integer> dealerVolume = new Map<Id, Integer>();
            if (!dealerIds.isEmpty() && !claimIds.isEmpty()) {
                for (AggregateResult ar : [
                    SELECT AccountId aid, COUNT(Id) cnt
                    FROM Claim
                    WHERE
                        AccountId IN :dealerIds
                        AND CreatedDate = LAST_N_DAYS:30
                        AND Id NOT IN :claimIds
                    GROUP BY AccountId
                ]) {
                    dealerVolume.put((Id) ar.get('aid'), (Integer) ar.get('cnt'));
                }
            }

            Map<String, List<Claim>> recentClaimsByVin = new Map<String, List<Claim>>();
            if (!claimVins.isEmpty()) {
                Datetime dupSince = Datetime.now().addDays(-7);
                for (Claim rc : [
                    SELECT Id, Name, Vehicle_VIN__c, AccountId, FailureDescription__c
                    FROM Claim
                    WHERE
                        Vehicle_VIN__c IN :claimVins
                        AND CreatedDate >= :dupSince
                        AND Id NOT IN :claimIds
                ]) {
                    if (!recentClaimsByVin.containsKey(rc.Vehicle_VIN__c)) {
                        recentClaimsByVin.put(rc.Vehicle_VIN__c, new List<Claim>());
                    }
                    recentClaimsByVin.get(rc.Vehicle_VIN__c).add(rc);
                }
            }

            Set<Id> activeProducts = new Set<Id>();
            if (!productIds.isEmpty()) {
                for (Product2 p : [SELECT Id FROM Product2 WHERE Id IN :productIds AND IsActive = TRUE]) {
                    activeProducts.add(p.Id);
                }
            }

            Map<Id, Output> calcByClaim = new Map<Id, Output>();
            List<Claim> toUpdate = new List<Claim>();

            for (Id cid : claimIds) {
                Claim c = claimById.get(cid);
                if (c == null) {
                    continue;
                }
                List<String> factorList = new List<String>();
                Set<String> flagSet = new Set<String>();
                Decimal score = 0;

                Id effAsset = assetIdByClaim.get(c.Id);
                Boolean hasActiveWarranty = effAsset != null && warrantiesByAsset.containsKey(effAsset);
                if (effAsset == null || !hasActiveWarranty) {
                    score += impact(rules, 'Warranty_Expired', 40);
                    factorList.add('Warranty inactive or missing at Electra claim time');
                    flagSet.add('Warranty_Expired');
                }

                Vehicle veh = effAsset != null ? vehicleByAssetId.get(effAsset) : null;
                if (effAsset == null || veh == null) {
                    score += impact(rules, 'VIN_Mismatch', 50);
                    factorList.add('Vehicle or insured asset missing for VIN validation');
                    flagSet.add('Vehicle_Mismatch');
                }

                Decimal usageCap = null;
                if (hasActiveWarranty && c.MileageAtClaim__c != null && effAsset != null && warrantiesByAsset.containsKey(effAsset)) {
                    for (AssetWarranty aw : warrantiesByAsset.get(effAsset)) {
                        if (aw.WarrantyTerm != null && aw.WarrantyTerm.UsageCovered != null) {
                            usageCap = aw.WarrantyTerm.UsageCovered;
                            break;
                        }
                    }
                    if (usageCap != null && c.MileageAtClaim__c > usageCap) {
                        score += impact(rules, 'Mileage_Exceeded', 30);
                        factorList.add('Claim mileage exceeds Electra warranty usage coverage');
                        flagSet.add('Mileage_Exceeded');
                    }
                }

                List<ClaimItem> cis = itemsByClaim.get(c.Id);
                Boolean partIssue = false;
                if (cis != null) {
                    for (ClaimItem ci : cis) {
                        if (ci.ProductId == null || !activeProducts.contains(ci.ProductId)) {
                            partIssue = true;
                            break;
                        }
                    }
                }
                if (partIssue) {
                    score += impact(rules, 'Part_Not_In_Catalog', 25);
                    factorList.add('Line item part missing or inactive in Electra parts catalog');
                    flagSet.add('Part_Not_Covered');
                }

                if (c.EstimatedAmount != null && c.EstimatedAmount > highAmtThreshold) {
                    score += impact(rules, 'High_Value_Claim', 20);
                    factorList.add('Estimated amount exceeds Electra high-value warranty threshold');
                    flagSet.add('High_Value_Claim');
                }

                Integer dv = c.AccountId != null && dealerVolume.containsKey(c.AccountId) ? dealerVolume.get(c.AccountId) : 0;
                if (dv > dealerVolThreshold) {
                    score += impact(rules, 'High_Volume_Dealer', 15);
                    factorList.add('Dealer claim volume anomaly in last 30 days');
                    flagSet.add('High_Volume_Dealer');
                }

                if (veh != null && veh.IsRecallOpen == true) {
                    score += impact(rules, 'Open_Recall', -10);
                    factorList.add('Open recall on vehicle (Electra risk adjustment)');
                    flagSet.add('Open_Recall');
                }

                if (String.isNotBlank(c.Vehicle_VIN__c) && recentClaimsByVin.containsKey(c.Vehicle_VIN__c)) {
                    List<Claim> priors = recentClaimsByVin.get(c.Vehicle_VIN__c);
                    String currentFault = normalizeFault(c.FailureDescription__c);
                    Boolean highConfidenceDup = false;
                    Integer matchedDealerFault = 0;
                    for (Claim prior : priors) {
                        Boolean sameDealer = (prior.AccountId == c.AccountId);
                        Boolean sameFault = (currentFault != null
                            && currentFault.length() > 0
                            && currentFault == normalizeFault(prior.FailureDescription__c));
                        if (sameDealer && sameFault) {
                            highConfidenceDup = true;
                            matchedDealerFault++;
                        }
                    }
                    if (highConfidenceDup) {
                        score += impact(rules, 'Duplicate_Claim_HighConfidence', 80);
                        factorList.add('Likely duplicate: ' + matchedDealerFault + ' recent claim(s) with same VIN, dealer, and fault description');
                        flagSet.add('High_Confidence_Duplicate');
                    } else {
                        score += impact(rules, 'Duplicate_Claim', 50);
                        factorList.add('Possible duplicate: ' + priors.size() + ' recent claim(s) on same VIN within last 7 days (different fault or dealer)');
                        flagSet.add('Duplicate_Claim');
                    }
                }

                score = Math.max(0, Math.min(100, score));

                String rec;
                if (score <= approveMax) {
                    rec = REC_APPROVE;
                } else if (score >= denyMin) {
                    rec = REC_DENY;
                } else {
                    rec = REC_REVIEW;
                }

                String notes = factorList.isEmpty() ? 'No elevated Electra warranty risk factors detected.' : String.join(factorList, '; ');
                String flagsCsv = flagSet.isEmpty() ? null : String.join(new List<String>(flagSet), ';');

                Output o = new Output();
                o.riskScore = score;
                o.recommendation = rec;
                o.triageNotes = notes;
                o.factors = String.join(factorList, ', ');
                o.message = 'Electra triage: score ' + score + ' → ' + rec;
                calcByClaim.put(c.Id, o);

                c.Risk_Score__c = score;
                c.AI_Recommendation__c = rec;
                c.AI_Triage_Notes__c = notes;
                c.Triage_Flags__c = flagsCsv;
                toUpdate.add(c);
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }

            for (Input inRow : inputs) {
                ordered.add(rowOutput(inRow, claimById, calcByClaim));
            }
            return ordered;
        } catch (Exception e) {
            List<Output> errs = new List<Output>();
            Output err = new Output();
            err.riskScore = -1;
            err.recommendation = REC_REVIEW;
            err.triageNotes = '';
            err.factors = '';
            err.message = 'Triage error: ' + e.getMessage();
            for (Integer i = 0; i < inputs.size(); i++) {
                errs.add(err);
            }
            return errs;
        }
    }

    private static Output rowOutput(Input inRow, Map<Id, Claim> claimById, Map<Id, Output> calcByClaim) {
        Output o = new Output();
        if (inRow == null || inRow.claimId == null) {
            o.riskScore = -1;
            o.recommendation = REC_REVIEW;
            o.message = 'Claim ID is required for Electra warranty triage';
            o.triageNotes = o.message;
            return o;
        }
        if (!claimById.containsKey(inRow.claimId)) {
            o.riskScore = -1;
            o.recommendation = REC_REVIEW;
            o.message = 'Claim not found for Electra triage';
            o.triageNotes = o.message;
            return o;
        }
        Output calc = calcByClaim.get(inRow.claimId);
        if (calc != null) {
            return calc;
        }
        o.riskScore = -1;
        o.recommendation = REC_REVIEW;
        o.message = 'Electra triage did not produce a result for this claim';
        o.triageNotes = o.message;
        return o;
    }

    private static Map<String, WC_Triage_Rule__mdt> loadRules() {
        Map<String, WC_Triage_Rule__mdt> m = new Map<String, WC_Triage_Rule__mdt>();
        for (WC_Triage_Rule__mdt r : [
            SELECT
                DeveloperName,
                Rule_Type__c,
                Score_Impact__c,
                Auto_Approve_Max__c,
                Auto_Deny_Min__c,
                Threshold_Value__c,
                Is_Active__c
            FROM WC_Triage_Rule__mdt
            WHERE Is_Active__c = TRUE
        ]) {
            m.put(r.DeveloperName, r);
        }
        return m;
    }

    private static Decimal impact(Map<String, WC_Triage_Rule__mdt> rules, String devName, Decimal fallback) {
        WC_Triage_Rule__mdt r = rules.get(devName);
        if (r != null && r.Score_Impact__c != null) {
            return r.Score_Impact__c;
        }
        return fallback;
    }

    private static String normalizeFault(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        String n = s.toLowerCase().replaceAll('[^a-z0-9 ]', ' ').replaceAll('\\s+', ' ').trim();
        return n.length() > 50 ? n.substring(0, 50) : n;
    }

    private static Decimal decRule(Map<String, WC_Triage_Rule__mdt> rules, String devName, String fieldApi, Decimal fallback) {
        WC_Triage_Rule__mdt r = rules.get(devName);
        if (r == null) {
            return fallback;
        }
        if (fieldApi == 'Auto_Approve_Max__c' && r.Auto_Approve_Max__c != null) {
            return r.Auto_Approve_Max__c;
        }
        if (fieldApi == 'Auto_Deny_Min__c' && r.Auto_Deny_Min__c != null) {
            return r.Auto_Deny_Min__c;
        }
        if (fieldApi == 'Threshold_Value__c' && r.Threshold_Value__c != null) {
            return r.Threshold_Value__c;
        }
        return fallback;
    }
}