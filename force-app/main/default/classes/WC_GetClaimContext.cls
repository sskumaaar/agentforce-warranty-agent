public with sharing class WC_GetClaimContext {

    public class Input {
        @InvocableVariable(required=true label='Claim Id')
        public String claimId;
    }

    public class Output {
        @InvocableVariable(label='Vehicle Info')
        public String VehicleInfo;

        @InvocableVariable(label='Warranty Info')
        public String WarrantyInfo;

        @InvocableVariable(label='Claim Items Info')
        public String ClaimItemsInfo;

        @InvocableVariable(label='Dealer Context')
        public String DealerContext;

        @InvocableVariable(label='Triage Info')
        public String TriageInfo;
    }

    @InvocableMethod(label='Get Claim Context' description='Retrieves comprehensive claim context for prompt template data grounding')
    public static List<Output> getClaimContext(List<Input> inputs) {
        List<Output> results = new List<Output>();

        Set<Id> claimIds = new Set<Id>();
        for (Input inp : inputs) {
            if (String.isNotBlank(inp.claimId)) {
                try { claimIds.add(inp.claimId); } catch (Exception e) { /* invalid Id */ }
            }
        }

        if (claimIds.isEmpty()) {
            for (Input inp : inputs) {
                results.add(buildEmptyOutput('Invalid or missing Claim Id'));
            }
            return results;
        }

        Map<Id, Claim> claimsMap = new Map<Id, Claim>([
            SELECT Id, Name, Status, StatusCode, Severity, Summary,
                   EstimatedAmount, AccountId, Account.Name, InsuredAssetId,
                   InitiationDate, Channel__c, FailureDescription__c,
                   DiagnosticTroubleCode__c, MileageAtClaim__c, DealerCode__c,
                   Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c
            FROM Claim
            WHERE Id IN :claimIds
        ]);

        Set<Id> assetIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        for (Claim c : claimsMap.values()) {
            if (c.InsuredAssetId != null) { assetIds.add(c.InsuredAssetId); }
            if (c.AccountId != null) { accountIds.add(c.AccountId); }
        }

        Map<Id, Vehicle> vehiclesByAsset = new Map<Id, Vehicle>();
        if (!assetIds.isEmpty()) {
            for (Vehicle v : [
                SELECT Id, VehicleIdentificationNumber, MakeName, ModelName,
                       ModelYear, ExteriorColor, LastOdometerReading, IsRecallOpen, AssetId
                FROM Vehicle WHERE AssetId IN :assetIds
            ]) {
                vehiclesByAsset.put(v.AssetId, v);
            }
        }

        Map<Id, List<AssetWarranty>> warrantiesByAsset = new Map<Id, List<AssetWarranty>>();
        if (!assetIds.isEmpty()) {
            for (AssetWarranty aw : [
                SELECT Id, AssetId, StartDate, EndDate, WarrantyType,
                       WarrantyTermId, WarrantyTerm.WarrantyTermName,
                       WarrantyTerm.UsageCovered
                FROM AssetWarranty
                WHERE AssetId IN :assetIds AND StartDate <= TODAY AND EndDate >= TODAY
                ORDER BY EndDate DESC
            ]) {
                if (!warrantiesByAsset.containsKey(aw.AssetId)) {
                    warrantiesByAsset.put(aw.AssetId, new List<AssetWarranty>());
                }
                warrantiesByAsset.get(aw.AssetId).add(aw);
            }
        }

        Map<Id, List<ClaimItem>> itemsByClaim = new Map<Id, List<ClaimItem>>();
        for (ClaimItem ci : [
            SELECT Id, Name, ClaimId, Description, ProductId,
                   Type__c, CausalPartNumber__c, Quantity__c,
                   UnitPrice__c, EstimatedAmount__c, LaborHours__c
            FROM ClaimItem WHERE ClaimId IN :claimIds
        ]) {
            if (!itemsByClaim.containsKey(ci.ClaimId)) {
                itemsByClaim.put(ci.ClaimId, new List<ClaimItem>());
            }
            itemsByClaim.get(ci.ClaimId).add(ci);
        }

        Map<Id, Integer> dealerClaimCounts = new Map<Id, Integer>();
        if (!accountIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AccountId, COUNT(Id) cnt
                FROM Claim
                WHERE AccountId IN :accountIds AND CreatedDate = LAST_N_DAYS:30
                GROUP BY AccountId
            ]) {
                dealerClaimCounts.put((Id) ar.get('AccountId'), (Integer) ar.get('cnt'));
            }
        }

        for (Input inp : inputs) {
            Claim c = String.isNotBlank(inp.claimId) ? claimsMap.get(inp.claimId) : null;
            if (c == null) {
                results.add(buildEmptyOutput('Claim not found'));
                continue;
            }
            results.add(buildOutput(c, vehiclesByAsset, warrantiesByAsset, itemsByClaim, dealerClaimCounts));
        }

        return results;
    }

    private static Output buildOutput(
        Claim c,
        Map<Id, Vehicle> vehiclesByAsset,
        Map<Id, List<AssetWarranty>> warrantiesByAsset,
        Map<Id, List<ClaimItem>> itemsByClaim,
        Map<Id, Integer> dealerClaimCounts
    ) {
        Output out = new Output();
        out.VehicleInfo = formatVehicle(c.InsuredAssetId, vehiclesByAsset);
        out.WarrantyInfo = formatWarranties(c.InsuredAssetId, warrantiesByAsset);
        out.ClaimItemsInfo = formatClaimItems(c.Id, itemsByClaim);
        out.DealerContext = formatDealerContext(c, dealerClaimCounts);
        out.TriageInfo = formatTriage(c);
        return out;
    }

    private static String formatVehicle(Id assetId, Map<Id, Vehicle> vehiclesByAsset) {
        if (assetId == null) { return 'Vehicle details not available (no asset linked)'; }
        Vehicle v = vehiclesByAsset.get(assetId);
        if (v == null) { return 'Vehicle details not found for this asset'; }

        return 'VIN: ' + safe(v.VehicleIdentificationNumber) +
            '\nModel: ' + safe(v.ModelYear) + ' ' + safe(v.MakeName) + ' ' + safe(v.ModelName) +
            '\nColor: ' + safe(v.ExteriorColor) +
            '\nOdometer: ' + (v.LastOdometerReading != null ? String.valueOf(v.LastOdometerReading.intValue()) + ' km' : 'Not recorded') +
            '\nRecall Status: ' + (v.IsRecallOpen == true ? 'OPEN RECALL' : 'No open recalls');
    }

    private static String formatWarranties(Id assetId, Map<Id, List<AssetWarranty>> warrantiesByAsset) {
        if (assetId == null) { return 'No warranty data (no asset linked)'; }
        List<AssetWarranty> warranties = warrantiesByAsset.get(assetId);
        if (warranties == null || warranties.isEmpty()) { return 'No active warranties found for this vehicle'; }

        List<String> lines = new List<String>();
        for (AssetWarranty aw : warranties) {
            String termName = (aw.WarrantyTerm != null && aw.WarrantyTerm.WarrantyTermName != null)
                ? aw.WarrantyTerm.WarrantyTermName : safe(aw.WarrantyType);
            String line = '- ' + termName + ': Active (' +
                String.valueOf(aw.StartDate) + ' to ' + String.valueOf(aw.EndDate) + ')';
            if (aw.WarrantyTerm != null && aw.WarrantyTerm.UsageCovered != null) {
                line += ', Coverage: ' + String.valueOf(aw.WarrantyTerm.UsageCovered) + ' km';
            }
            lines.add(line);
        }
        return String.join(lines, '\n');
    }

    private static String formatClaimItems(Id claimId, Map<Id, List<ClaimItem>> itemsByClaim) {
        List<ClaimItem> items = itemsByClaim.get(claimId);
        if (items == null || items.isEmpty()) { return 'No claim line items found'; }

        List<String> lines = new List<String>();
        for (ClaimItem ci : items) {
            String line = '- ';
            if (ci.Type__c != null) { line += ci.Type__c + ': '; }
            line += safe(ci.Description);
            if (ci.CausalPartNumber__c != null) { line += ' (P/N: ' + ci.CausalPartNumber__c + ')'; }
            if (ci.Quantity__c != null) { line += ', Qty: ' + String.valueOf(ci.Quantity__c.intValue()); }
            if (ci.UnitPrice__c != null) { line += ', Unit: $' + ci.UnitPrice__c.setScale(2).toPlainString(); }
            if (ci.EstimatedAmount__c != null) { line += ', Amount: $' + ci.EstimatedAmount__c.setScale(2).toPlainString(); }
            if (ci.LaborHours__c != null) { line += ', Labor: ' + String.valueOf(ci.LaborHours__c) + ' hrs'; }
            lines.add(line);
        }
        return String.join(lines, '\n');
    }

    private static String formatDealerContext(Claim c, Map<Id, Integer> dealerClaimCounts) {
        String dealerName = (c.Account != null) ? c.Account.Name : 'Unknown Dealer';
        String dealerCode = safe(c.DealerCode__c);
        Integer count = (c.AccountId != null && dealerClaimCounts.containsKey(c.AccountId))
            ? dealerClaimCounts.get(c.AccountId) : 0;
        return 'Dealer: ' + dealerName + ' (' + dealerCode + ')' +
            '\nClaims in last 30 days: ' + String.valueOf(count);
    }

    private static String formatTriage(Claim c) {
        String score = (c.Risk_Score__c != null) ? String.valueOf(c.Risk_Score__c.intValue()) + '/100' : 'Not scored';
        String recommendation = safe(c.AI_Recommendation__c, 'Pending');
        String notes = safe(c.AI_Triage_Notes__c, 'No triage notes');
        return 'Risk Score: ' + score +
            '\nRecommendation: ' + recommendation +
            '\nNotes: ' + notes;
    }

    private static Output buildEmptyOutput(String reason) {
        Output out = new Output();
        out.VehicleInfo = reason;
        out.WarrantyInfo = 'No data available';
        out.ClaimItemsInfo = 'No data available';
        out.DealerContext = 'No data available';
        out.TriageInfo = 'No data available';
        return out;
    }

    private static String safe(String val) {
        return String.isNotBlank(val) ? val : 'Not provided';
    }

    private static String safe(String val, String fallback) {
        return String.isNotBlank(val) ? val : fallback;
    }
}