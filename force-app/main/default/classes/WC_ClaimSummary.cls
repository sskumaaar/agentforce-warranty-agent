// Read-only summary used by the Approver Agent. Runs without sharing so all approver users see all claims.
public without sharing class WC_ClaimSummary {

    public class SummaryRequest {
        @InvocableVariable(label='Claim Id' description='Salesforce 15/18-char record Id (single mode). Use Claim Number instead if user provided a Name string.')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='PRIMARY parameter for single mode. Claim Name string. Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007. Pass exactly as user provided.')
        public String claimNumber;

        @InvocableVariable(label='Mode' description='Pass exactly one of: "single" (default — deep summary of one claim, requires claimNumber or claimId), "queue" (snapshot of top pending claims), "aggregate" (org-wide totals like total claim count, average risk score). Use "single" for "summarize WC-XXX". Use "queue" for "queue summary". Use "aggregate" for "overall metrics".')
        public String mode;

        @InvocableVariable(label='Limit' description='Maximum claims to include when mode="queue". Default 10, max 50.')
        public Integer limitCount;
    }

    public class SummaryResponse {
        // ONLY this field is exposed to the agent. Internal fields below are public for Apex tests.
        @InvocableVariable(label='Response' description='Formatted plain-text claim summary. Present verbatim.')
        public String message;

        public String claimNumber;
        public String status;
        public String severity;
        public String summary;
        public Decimal totalClaimedAmount;
        public String vehicleInfo;
        public String warrantyInfo;
        public String dealerName;
        public String claimItems;
        public Integer riskScore;
        public String aiRecommendation;
        public String aiTriageNotes;
        public Integer dealerClaimCount30Days;
        public Date initiationDate;
        public Integer daysPending;
        public String errorMessage;
    }

    @InvocableMethod(
        label='Summarize Claim'
        description='Pending queue, single-claim detail, or aggregate claim metrics for Electra Cars warranty approvers'
    )
    public static List<SummaryResponse> summarize(List<SummaryRequest> requests) {
        List<SummaryResponse> results = new List<SummaryResponse>();
        if (requests == null) {
            return results;
        }
        for (SummaryRequest req : requests) {
            results.add(process(req));
        }
        return results;
    }

    private static SummaryResponse process(SummaryRequest req) {
        SummaryResponse out = new SummaryResponse();
        String mode = String.isBlank(req.mode) ? 'single' : req.mode.trim().toLowerCase();
        if (mode == 'queue') {
            return buildQueueSummary(req, out);
        }
        if (mode == 'aggregate') {
            return buildAggregateSummary(out);
        }
        return buildSingleSummary(req, out);
    }

    private static SummaryResponse buildQueueSummary(SummaryRequest req, SummaryResponse out) {
        Integer lim = (req.limitCount != null && req.limitCount > 0) ? Math.min(req.limitCount, 50) : 10;
        try {
            List<Claim> claims = [
                SELECT Id, Name, Status, EstimatedAmount, Account.Name, Risk_Score__c,
                       AI_Recommendation__c, InsuredAssetId, InitiationDate
                FROM Claim
                WHERE Status IN ('New', 'Under Review', 'Submitted', 'Requested Information')
                ORDER BY Risk_Score__c DESC NULLS LAST, InitiationDate ASC
                LIMIT :lim
            ];
            Set<Id> claimIds = new Map<Id, Claim>(claims).keySet();
            Map<Id, Id> claimToVehicleId = new Map<Id, Id>();
            for (ClaimItem ci : [
                SELECT ClaimId, VehicleId FROM ClaimItem WHERE ClaimId IN :claimIds AND VehicleId != null
            ]) {
                if (!claimToVehicleId.containsKey(ci.ClaimId)) {
                    claimToVehicleId.put(ci.ClaimId, ci.VehicleId);
                }
            }
            Set<Id> vehicleIds = new Set<Id>(claimToVehicleId.values());
            Map<Id, Vehicle> vehiclesById = new Map<Id, Vehicle>();
            if (!vehicleIds.isEmpty()) {
                for (Vehicle v : [
                    SELECT Id, MakeName, ModelName, ModelYear
                    FROM Vehicle WHERE Id IN :vehicleIds
                ]) {
                    vehiclesById.put(v.Id, v);
                }
            }
            if (claims.isEmpty()) {
                out.summary = 'No pending Electra Cars warranty claims in queue.';
                out.claimNumber = '(queue)';
                out.message = '✅ No pending claims in the queue.';
                return out;
            }
            Decimal totalAmt = 0;
            List<String> lines = new List<String>();
            Integer idx = 1;
            for (Claim c : claims) {
                if (c.EstimatedAmount != null) {
                    totalAmt += c.EstimatedAmount;
                }
                String vLabel = 'Vehicle N/A';
                Vehicle v = claimToVehicleId.containsKey(c.Id) ? vehiclesById.get(claimToVehicleId.get(c.Id)) : null;
                if (v != null) {
                    vLabel = String.valueOf(v.ModelYear) + ' ' + v.MakeName + ' ' + v.ModelName;
                }
                Integer rs = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : 0;
                String dealer = (c.Account != null) ? c.Account.Name : 'Unknown';
                lines.add(
                    idx + '. ' + c.Name + ' | $' +
                    (c.EstimatedAmount != null ? c.EstimatedAmount.setScale(0).toPlainString() : '0') +
                    ' | Risk ' + rs + '/100 | ' + dealer + ' | ' + vLabel
                );
                idx++;
            }
            out.summary = 'Pending Electra Cars queue (top ' + claims.size() + '):\n\n' + String.join(lines, '\n');
            out.totalClaimedAmount = totalAmt;
            out.claimNumber = claims[0].Name;
            out.message = '📋 Pending Queue (top ' + claims.size() + ', total $' +
                totalAmt.setScale(0).toPlainString() + ')\n━━━━━━━━━━━━━━━━━━━━━━━\n\n' +
                String.join(lines, '\n');
            return out;
        } catch (Exception e) {
            out.errorMessage = 'Queue summary failed: ' + e.getMessage();
            out.message = '⚠️ Queue summary failed: ' + e.getMessage();
            return out;
        }
    }

    private static SummaryResponse buildAggregateSummary(SummaryResponse out) {
        try {
            Integer total = [SELECT COUNT() FROM Claim];
            Integer pending = [
                SELECT COUNT() FROM Claim WHERE Status IN ('New', 'Under Review', 'Submitted', 'Requested Information')
            ];
            AggregateResult[] avgs = [SELECT AVG(Risk_Score__c) avgr FROM Claim WHERE Risk_Score__c != null];
            Decimal avgRisk = avgs.isEmpty() ? null : (Decimal) avgs[0].get('avgr');
            out.summary = 'AGGREGATE — Electra Cars warranty claims\nTotal claims: ' + total +
                '\nRecently touched pending-style snapshot: ' + pending +
                (avgRisk != null ? '\nAvg risk score: ' + avgRisk.setScale(1) + '/100' : '');
            out.claimNumber = '(aggregate)';
            out.message = '📊 Aggregate Snapshot\n━━━━━━━━━━━━━━━━━━━━━━━\n' +
                'Total claims: ' + total + '\n' +
                'Pending: ' + pending +
                (avgRisk != null ? '\nAvg risk score: ' + avgRisk.setScale(1) + '/100' : '');
            return out;
        } catch (Exception e) {
            out.errorMessage = 'Aggregate metrics failed: ' + e.getMessage();
            out.message = '⚠️ Aggregate metrics failed: ' + e.getMessage();
            return out;
        }
    }

    private static SummaryResponse buildSingleSummary(SummaryRequest req, SummaryResponse out) {
        if (String.isBlank(req.claimId) && String.isBlank(req.claimNumber)) {
            out.errorMessage = 'Claim Id or Claim Number is required for single mode.';
            out.message = '⚠️ Please provide a claim number (e.g. WC-001227) or Claim Id.';
            return out;
        }
        Id cid;
        if (String.isNotBlank(req.claimId)) {
            try { cid = Id.valueOf(req.claimId.trim()); } catch (Exception e) { cid = null; }
        }
        if (cid == null && String.isNotBlank(req.claimNumber)) {
            List<Claim> byName = [SELECT Id FROM Claim WHERE Name = :req.claimNumber.trim() LIMIT 1];
            if (!byName.isEmpty()) { cid = byName[0].Id; }
        }
        if (cid == null) {
            out.errorMessage = 'Could not resolve Claim from the provided Id or Number.';
            out.message = '⚠️ Could not find claim ' +
                (String.isNotBlank(req.claimNumber) ? req.claimNumber : req.claimId) + '.';
            return out;
        }
        List<Claim> rows = [
            SELECT Id, Name, Status, StatusCode, Severity, Summary, EstimatedAmount,
                   AccountId, Account.Name, InitiationDate, Risk_Score__c,
                   AI_Recommendation__c, AI_Triage_Notes__c, InsuredAssetId, DealerCode__c
            FROM Claim WHERE Id = :cid LIMIT 1
        ];
        if (rows.isEmpty()) {
            out.errorMessage = 'Claim not found.';
            out.message = '⚠️ Claim not found.';
            return out;
        }
        Claim c = rows[0];
        out.claimNumber = c.Name;
        out.status = c.Status;
        out.severity = String.valueOf(c.Severity);
        out.summary = c.Summary;
        out.totalClaimedAmount = c.EstimatedAmount;
        out.dealerName = (c.AccountId != null && c.Account != null) ? c.Account.Name : null;
        if (c.Risk_Score__c != null) {
            out.riskScore = c.Risk_Score__c.intValue();
        }
        out.aiRecommendation = c.AI_Recommendation__c;
        out.aiTriageNotes = c.AI_Triage_Notes__c;

        if (c.InitiationDate != null) {
            Object rawInit = c.get('InitiationDate');
            Date idResolved;
            if (rawInit instanceof Date) {
                idResolved = (Date) rawInit;
            } else if (rawInit instanceof Datetime) {
                idResolved = ((Datetime) rawInit).date();
            }
            if (idResolved != null) {
                out.initiationDate = idResolved;
                out.daysPending = idResolved.daysBetween(Date.today());
            }
        }

        List<ClaimItem> ciWithVehicle = [
            SELECT VehicleId FROM ClaimItem WHERE ClaimId = :c.Id AND VehicleId != null LIMIT 1
        ];
        if (!ciWithVehicle.isEmpty()) {
            List<Vehicle> vl = [
                SELECT Id, AssetId, VehicleIdentificationNumber, MakeName, ModelName, ModelYear, ExteriorColor
                FROM Vehicle WHERE Id = :ciWithVehicle[0].VehicleId LIMIT 1
            ];
            if (!vl.isEmpty()) {
                Vehicle v = vl[0];
                out.vehicleInfo = v.ModelYear + ' ' + v.MakeName + ' ' + v.ModelName +
                    ' | VIN ' + v.VehicleIdentificationNumber + ' | Color ' + v.ExteriorColor;
                if (v.AssetId != null) {
                    List<AssetWarranty> awl = [
                        SELECT StartDate, EndDate, WarrantyType, WarrantyTerm.WarrantyTermName
                        FROM AssetWarranty
                        WHERE AssetId = :v.AssetId AND StartDate <= TODAY AND EndDate >= TODAY
                        ORDER BY EndDate DESC LIMIT 3
                    ];
                    List<String> wl = new List<String>();
                    for (AssetWarranty aw : awl) {
                        String term = (aw.WarrantyTerm != null && aw.WarrantyTerm.WarrantyTermName != null)
                            ? aw.WarrantyTerm.WarrantyTermName : String.valueOf(aw.WarrantyType);
                        wl.add(term + ' until ' + aw.EndDate);
                    }
                    out.warrantyInfo = wl.isEmpty() ? 'No active warranty rows for asset' : String.join(wl, '; ');
                }
            }
        }
        for (ClaimItem ci : [
            SELECT Description, Type__c, EstimatedAmount__c FROM ClaimItem WHERE ClaimId = :c.Id LIMIT 20
        ]) {
            String line = (ci.Type__c != null ? ci.Type__c + ': ' : '') + ci.Description;
            out.claimItems = (out.claimItems == null ? '' : out.claimItems + '\n') + line;
        }
        if (c.AccountId != null) {
            out.dealerClaimCount30Days = [
                SELECT COUNT() FROM Claim WHERE AccountId = :c.AccountId AND CreatedDate = LAST_N_DAYS:30
            ];
        }

        // Build the rich plain-text message that the agent shows verbatim.
        Integer rs = (out.riskScore != null) ? out.riskScore : 0;
        String riskIcon = '⚪';
        String riskLevel = 'Unknown';
        if (rs >= 80) { riskIcon = '🔴'; riskLevel = 'Critical'; }
        else if (rs >= 50) { riskIcon = '🟠'; riskLevel = 'High'; }
        else if (rs >= 21) { riskIcon = '🟡'; riskLevel = 'Medium'; }
        else if (rs > 0)   { riskIcon = '🟢'; riskLevel = 'Low'; }
        String statusIcon;
        if (c.Status == 'Approved') { statusIcon = '✅'; }
        else if (c.Status == 'Denied') { statusIcon = '🚫'; }
        else if (c.Status == 'Requested Information') { statusIcon = '⏳'; }
        else { statusIcon = '📋'; }

        List<String> ml = new List<String>();
        ml.add(statusIcon + ' Claim ' + c.Name + ' — Full Summary');
        ml.add('━━━━━━━━━━━━━━━━━━━━━━━');
        ml.add('Status: ' + c.Status);
        ml.add('Severity: ' + (c.Severity != null ? String.valueOf(c.Severity) : '—'));
        ml.add('Risk Score: ' + riskIcon + ' ' + rs + ' / 100 (' + riskLevel + ')');
        if (c.AI_Recommendation__c != null) { ml.add('AI Recommendation: ' + c.AI_Recommendation__c); }
        if (c.EstimatedAmount != null) { ml.add('Estimated Amount: $' + c.EstimatedAmount.setScale(2).toPlainString()); }
        if (out.dealerName != null) { ml.add('Dealer: ' + out.dealerName); }
        if (out.daysPending != null) { ml.add('Days Pending: ' + out.daysPending); }
        if (out.vehicleInfo != null) { ml.add('Vehicle: ' + out.vehicleInfo); }
        if (out.warrantyInfo != null) { ml.add('Warranty: ' + out.warrantyInfo); }
        if (out.claimItems != null) {
            ml.add('');
            ml.add('Claim Items:');
            ml.add(out.claimItems);
        }
        if (out.aiTriageNotes != null && out.aiTriageNotes != '') {
            ml.add('');
            ml.add('AI Triage Notes: ' + out.aiTriageNotes);
        }
        if (out.dealerClaimCount30Days != null) {
            ml.add('');
            ml.add('Dealer activity: ' + out.dealerClaimCount30Days + ' claim(s) in last 30 days');
        }
        out.message = String.join(ml, '\n');
        return out;
    }
}