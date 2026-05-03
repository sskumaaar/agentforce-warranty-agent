/**
 * WC_VehicleClaimAnalyticsController
 * Returns claim analytics grouped by vehicle model for the
 * wcVehicleClaimAnalytics LWC on the Claim Command Center Analytics tab.
 *
 * Query chain (2-step per FIELD_NAME_CORRECTIONS_CRITICAL.md):
 *   Step 1 — Claim + ClaimItems subquery  (ClaimItem.AssetId, Category)
 *   Step 2 — Vehicle WHERE AssetId IN :assetIds  (dynamic SOQL — Vehicle
 *             is an Automotive Cloud SObject not available as a static type)
 *
 * Claim fields used (corrected names from FIELD_NAME_CORRECTIONS_CRITICAL.md):
 *   Severity, ClaimReason, TotalClaimedAmount, Status, InitiationDate
 * ClaimItem fields used:
 *   AssetId (links to Vehicle.AssetId), Category
 * Vehicle fields used (dynamic):
 *   Name, AssetId
 */
public with sharing class WC_VehicleClaimAnalyticsController {

    // ── Top-level response ────────────────────────────────────────────────────
    public class AnalyticsResult {
        @AuraEnabled public List<VehicleSummary> vehicles     { get; set; }
        @AuraEnabled public List<String>         allCategories { get; set; }
        @AuraEnabled public List<String>         allSeverities { get; set; }
        @AuraEnabled public Integer              totalClaims  { get; set; }
        @AuraEnabled public Decimal              totalAmount  { get; set; }

        public AnalyticsResult() {
            this.vehicles      = new List<VehicleSummary>();
            this.allCategories = new List<String>();
            this.allSeverities = new List<String>();
            this.totalClaims   = 0;
            this.totalAmount   = 0;
        }
    }

    // ── Per-vehicle summary ───────────────────────────────────────────────────
    public class VehicleSummary {
        @AuraEnabled public String             vehicleLabel { get; set; }
        @AuraEnabled public Integer            claimCount    { get; set; }
        @AuraEnabled public Decimal            totalAmount   { get; set; }
        @AuraEnabled public Decimal            avgAmount     { get; set; }
        @AuraEnabled public Integer            widthPct      { get; set; }
        @AuraEnabled public Integer            approvedCount { get; set; }
        @AuraEnabled public Integer            deniedCount   { get; set; }
        @AuraEnabled public String             topCategory   { get; set; }
        @AuraEnabled public String             topSeverity   { get; set; }
        @AuraEnabled public List<BreakdownRow> categories    { get; set; }
        @AuraEnabled public List<BreakdownRow> severities    { get; set; }
        @AuraEnabled public List<BreakdownRow> statuses      { get; set; }
        @AuraEnabled public List<BreakdownRow> reasons       { get; set; }

        public VehicleSummary(String lbl) {
            this.vehicleLabel  = lbl;
            this.claimCount    = 0;
            this.totalAmount   = 0;
            this.avgAmount     = 0;
            this.widthPct      = 0;
            this.approvedCount = 0;
            this.deniedCount   = 0;
            this.topCategory   = '';
            this.topSeverity   = '';
            this.categories    = new List<BreakdownRow>();
            this.severities    = new List<BreakdownRow>();
            this.statuses      = new List<BreakdownRow>();
            this.reasons       = new List<BreakdownRow>();
        }
    }

    // ── Single breakdown slice ────────────────────────────────────────────────
    public class BreakdownRow {
        @AuraEnabled public String  label    { get; set; }
        @AuraEnabled public Integer count    { get; set; }
        @AuraEnabled public Integer widthPct { get; set; }
        @AuraEnabled public Decimal amount   { get; set; }

        public BreakdownRow(String lbl, Integer cnt, Decimal amt) {
            this.label    = String.isBlank(lbl) ? 'Unknown' : lbl;
            this.count    = cnt;
            this.amount   = amt;
            this.widthPct = 0;
        }
    }

    // ── Main entry point ─────────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static AnalyticsResult getVehicleClaimAnalytics() {
        AnalyticsResult result = new AnalyticsResult();

        // ── Step 1: Claim + ClaimItems (AssetId + Category) ──────────────────
        List<Claim> claimList = [
            SELECT Id, Name, Status, Severity, ClaimReason,
                   EstimatedAmount, CreatedDate,
                   (SELECT Id, AssetId, Category
                    FROM ClaimItems
                    ORDER BY CreatedDate ASC
                    LIMIT 1)
            FROM Claim
            ORDER BY CreatedDate DESC NULLS LAST
            LIMIT 2000
        ];

        if (claimList.isEmpty()) {
            return result;
        }

        // ── Step 2: Collect AssetIds → query Vehicle for Name labels ──────────
        Set<Id> assetIds = new Set<Id>();
        for (Claim c : claimList) {
            for (ClaimItem ci : c.ClaimItems) {
                if (ci.AssetId != null) {
                    assetIds.add(ci.AssetId);
                }
            }
        }

        // Vehicle is an Automotive Cloud SObject — use dynamic SOQL
        // Step 2a: Get Vehicle records + VehicleDefinitionId
        Map<Id, String> assetIdToVehicleName = new Map<Id, String>();
        if (!assetIds.isEmpty()) {
            try {
                // Collect VehicleDefinitionIds in same pass
                Set<Id> vdefIds = new Set<Id>();
                Map<Id, Id> assetIdToVdefId = new Map<Id, Id>();

                List<SObject> vehicles = Database.query(
                    'SELECT Id, Name, AssetId, VehicleDefinitionId FROM Vehicle ' +
                    'WHERE AssetId IN :assetIds ' +
                    'WITH SECURITY_ENFORCED'
                );
                for (SObject v : vehicles) {
                    Id aid   = (Id) v.get('AssetId');
                    Id vdefId = (Id) v.get('VehicleDefinitionId');
                    if (vdefId != null) {
                        vdefIds.add(vdefId);
                        if (aid != null) assetIdToVdefId.put(aid, vdefId);
                    } else if (aid != null) {
                        // fallback to Vehicle.Name if no VehicleDefinition
                        String nm = (String) v.get('Name');
                        if (String.isNotBlank(nm)) assetIdToVehicleName.put(aid, nm);
                    }
                }

                // Step 2b: Query VehicleDefinition for VariantName
                if (!vdefIds.isEmpty()) {
                    Map<Id, String> vdefIdToVariant = new Map<Id, String>();
                    List<SObject> vdefs = Database.query(
                        'SELECT Id, VariantName FROM VehicleDefinition ' +
                        'WHERE Id IN :vdefIds ' +
                        'WITH SECURITY_ENFORCED'
                    );
                    for (SObject vd : vdefs) {
                        Id    vdId    = (Id)     vd.get('Id');
                        String variant = (String) vd.get('VariantName');
                        if (String.isNotBlank(variant)) vdefIdToVariant.put(vdId, variant);
                    }
                    // Map assetId → VariantName
                    for (Id aid : assetIdToVdefId.keySet()) {
                        Id vdId = assetIdToVdefId.get(aid);
                        if (vdefIdToVariant.containsKey(vdId)) {
                            assetIdToVehicleName.put(aid, vdefIdToVariant.get(vdId));
                        }
                    }
                }
            } catch (Exception ex) {
                System.debug('WC_VehicleClaimAnalytics: Vehicle/VehicleDefinition query failed: ' + ex.getMessage());
            }
        }

        // ── Step 3: Aggregate by vehicle label ────────────────────────────────
        Map<String, Integer> vehicleClaimCount = new Map<String, Integer>();
        Map<String, Decimal> vehicleAmount     = new Map<String, Decimal>();

        Map<String, Map<String, Integer>> vehicleCategoryCount  = new Map<String, Map<String, Integer>>();
        Map<String, Map<String, Decimal>> vehicleCategoryAmount = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Integer>> vehicleSeverityCount  = new Map<String, Map<String, Integer>>();
        Map<String, Map<String, Integer>> vehicleStatusCount    = new Map<String, Map<String, Integer>>();
        Map<String, Map<String, Integer>> vehicleReasonCount    = new Map<String, Map<String, Integer>>();
        Map<String, Integer>              vehicleApprovedCount  = new Map<String, Integer>();
        Map<String, Integer>              vehicleDeniedCount    = new Map<String, Integer>();

        Set<String> allCatSet = new Set<String>();
        Set<String> allSevSet = new Set<String>();

        for (Claim c : claimList) {
            String vehicleLabel = 'Unknown Vehicle';
            String category     = 'Unknown';

            if (!c.ClaimItems.isEmpty()) {
                ClaimItem ci = c.ClaimItems[0];
                if (String.isNotBlank(ci.Category)) category = ci.Category;
                if (ci.AssetId != null && assetIdToVehicleName.containsKey(ci.AssetId)) {
                    vehicleLabel = assetIdToVehicleName.get(ci.AssetId);
                }
            }

            String  severity    = String.isNotBlank(c.Severity)    ? c.Severity    : 'Unknown';
            String  status      = String.isNotBlank(c.Status)      ? c.Status      : 'Unknown';
            String  claimReason = String.isNotBlank(c.ClaimReason) ? c.ClaimReason : 'Unknown';
            Decimal claimAmt    = c.EstimatedAmount != null ? c.EstimatedAmount : 0;

            allCatSet.add(category);
            allSevSet.add(severity);

            // totals
            vehicleClaimCount.put(vehicleLabel,
                (vehicleClaimCount.containsKey(vehicleLabel) ? vehicleClaimCount.get(vehicleLabel) : 0) + 1);
            vehicleAmount.put(vehicleLabel,
                (vehicleAmount.containsKey(vehicleLabel) ? vehicleAmount.get(vehicleLabel) : 0) + claimAmt);

            // category
            if (!vehicleCategoryCount.containsKey(vehicleLabel)) {
                vehicleCategoryCount.put(vehicleLabel, new Map<String, Integer>());
                vehicleCategoryAmount.put(vehicleLabel, new Map<String, Decimal>());
            }
            Map<String, Integer> catCnt = vehicleCategoryCount.get(vehicleLabel);
            Map<String, Decimal> catAmt = vehicleCategoryAmount.get(vehicleLabel);
            catCnt.put(category, (catCnt.containsKey(category) ? catCnt.get(category) : 0) + 1);
            catAmt.put(category, (catAmt.containsKey(category) ? catAmt.get(category) : 0) + claimAmt);

            // severity
            if (!vehicleSeverityCount.containsKey(vehicleLabel)) {
                vehicleSeverityCount.put(vehicleLabel, new Map<String, Integer>());
            }
            Map<String, Integer> sevMap = vehicleSeverityCount.get(vehicleLabel);
            sevMap.put(severity, (sevMap.containsKey(severity) ? sevMap.get(severity) : 0) + 1);

            // status
            if (!vehicleStatusCount.containsKey(vehicleLabel)) {
                vehicleStatusCount.put(vehicleLabel, new Map<String, Integer>());
            }
            Map<String, Integer> stMap = vehicleStatusCount.get(vehicleLabel);
            stMap.put(status, (stMap.containsKey(status) ? stMap.get(status) : 0) + 1);

            // approved / denied counts
            if (status == 'Approved') {
                vehicleApprovedCount.put(vehicleLabel,
                    (vehicleApprovedCount.containsKey(vehicleLabel) ? vehicleApprovedCount.get(vehicleLabel) : 0) + 1);
            } else if (status == 'Denied') {
                vehicleDeniedCount.put(vehicleLabel,
                    (vehicleDeniedCount.containsKey(vehicleLabel) ? vehicleDeniedCount.get(vehicleLabel) : 0) + 1);
            }

            // claim reason
            if (!vehicleReasonCount.containsKey(vehicleLabel)) {
                vehicleReasonCount.put(vehicleLabel, new Map<String, Integer>());
            }
            Map<String, Integer> rnMap = vehicleReasonCount.get(vehicleLabel);
            rnMap.put(claimReason, (rnMap.containsKey(claimReason) ? rnMap.get(claimReason) : 0) + 1);
        }

        // ── Step 4: Build VehicleSummary list ────────────────────────────────
        List<VehicleSummary> summaries = new List<VehicleSummary>();
        Integer maxCount   = 0;
        Decimal grandTotal = 0;
        Integer grandCount = 0;

        for (String vLabel : vehicleClaimCount.keySet()) {
            Integer cnt = vehicleClaimCount.get(vLabel);
            Decimal amt = vehicleAmount.get(vLabel);

            VehicleSummary vs = new VehicleSummary(vLabel);
            vs.claimCount      = cnt;
            vs.totalAmount     = amt;
            vs.avgAmount       = cnt > 0 ? (amt / cnt).setScale(0) : 0;
            vs.approvedCount   = vehicleApprovedCount.containsKey(vLabel) ? vehicleApprovedCount.get(vLabel) : 0;
            vs.deniedCount     = vehicleDeniedCount.containsKey(vLabel)   ? vehicleDeniedCount.get(vLabel)   : 0;

            if (cnt > maxCount) maxCount = cnt;
            grandTotal += amt;
            grandCount += cnt;

            // Category rows
            Map<String, Integer> catCnt = vehicleCategoryCount.containsKey(vLabel)
                ? vehicleCategoryCount.get(vLabel) : new Map<String, Integer>();
            Map<String, Decimal> catAmt = vehicleCategoryAmount.containsKey(vLabel)
                ? vehicleCategoryAmount.get(vLabel) : new Map<String, Decimal>();
            Integer maxCat = 0;
            String  topCat = '';
            Integer topCatCnt = 0;
            for (Integer v2 : catCnt.values()) if (v2 > maxCat) maxCat = v2;
            for (String cat : catCnt.keySet()) {
                Integer c2 = catCnt.get(cat);
                Decimal a2 = catAmt.containsKey(cat) ? catAmt.get(cat) : 0;
                BreakdownRow br = new BreakdownRow(cat, c2, a2);
                br.widthPct = maxCat > 0 ? (Integer) Math.round((Decimal) c2 / maxCat * 100) : 0;
                vs.categories.add(br);
                if (c2 > topCatCnt) { topCatCnt = c2; topCat = cat; }
            }
            vs.topCategory = topCat;

            // Severity rows
            Map<String, Integer> sevMap = vehicleSeverityCount.containsKey(vLabel)
                ? vehicleSeverityCount.get(vLabel) : new Map<String, Integer>();
            Integer maxSev = 0;
            String  topSev = '';
            Integer topSevCnt = 0;
            for (Integer v2 : sevMap.values()) if (v2 > maxSev) maxSev = v2;
            for (String sev : sevMap.keySet()) {
                Integer c2 = sevMap.get(sev);
                BreakdownRow br = new BreakdownRow(sev, c2, 0);
                br.widthPct = maxSev > 0 ? (Integer) Math.round((Decimal) c2 / maxSev * 100) : 0;
                vs.severities.add(br);
                if (c2 > topSevCnt) { topSevCnt = c2; topSev = sev; }
            }
            vs.topSeverity = topSev;

            // Reason rows
            Map<String, Integer> rnMap = vehicleReasonCount.containsKey(vLabel)
                ? vehicleReasonCount.get(vLabel) : new Map<String, Integer>();
            Integer maxRn = 0;
            for (Integer v2 : rnMap.values()) if (v2 > maxRn) maxRn = v2;
            for (String rn : rnMap.keySet()) {
                Integer c2 = rnMap.get(rn);
                BreakdownRow br = new BreakdownRow(rn, c2, 0);
                br.widthPct = maxRn > 0 ? (Integer) Math.round((Decimal) c2 / maxRn * 100) : 0;
                vs.reasons.add(br);
            }

            // Status rows
            Map<String, Integer> stMap = vehicleStatusCount.containsKey(vLabel)
                ? vehicleStatusCount.get(vLabel) : new Map<String, Integer>();
            Integer maxSt = 0;
            for (Integer v2 : stMap.values()) if (v2 > maxSt) maxSt = v2;
            for (String st : stMap.keySet()) {
                Integer c2 = stMap.get(st);
                BreakdownRow br = new BreakdownRow(st, c2, 0);
                br.widthPct = maxSt > 0 ? (Integer) Math.round((Decimal) c2 / maxSt * 100) : 0;
                vs.statuses.add(br);
            }

            summaries.add(vs);
        }

        // widthPct relative to max vehicle
        for (VehicleSummary vs : summaries) {
            vs.widthPct = maxCount > 0
                ? (Integer) Math.round((Decimal) vs.claimCount / maxCount * 100) : 0;
        }

        // Sort descending by claimCount
        for (Integer i = 1; i < summaries.size(); i++) {
            VehicleSummary key = summaries[i];
            Integer j = i - 1;
            while (j >= 0 && summaries[j].claimCount < key.claimCount) {
                summaries[j + 1] = summaries[j];
                j--;
            }
            summaries[j + 1] = key;
        }

        result.vehicles      = summaries;
        result.allCategories = new List<String>(allCatSet);
        result.allSeverities = new List<String>(allSevSet);
        result.totalClaims   = grandCount;
        result.totalAmount   = grandTotal;

        return result;
    }
}