/**
 * WCDealerKpiCardsController
 * Returns KPI aggregate counts for the Dealer Portal KPI Cards LWC.
 * Uses the standard Claim object with corrected field names per FIELD_NAME_CORRECTIONS_CRITICAL.md
 */
public with sharing class WCDealerKpiCardsController {

    public class KpiData {
        @AuraEnabled public Integer actionRequired    { get; set; }
        @AuraEnabled public Integer openClaims        { get; set; }
        @AuraEnabled public Integer underReview       { get; set; }
        @AuraEnabled public Integer approvedYtd       { get; set; }
        @AuraEnabled public Decimal avgApprovalDays   { get; set; }
        @AuraEnabled public Decimal approvalRate      { get; set; }

        public KpiData() {
            this.actionRequired  = 0;
            this.openClaims      = 0;
            this.underReview     = 0;
            this.approvedYtd     = 0;
            this.avgApprovalDays = 4.2;
            this.approvalRate    = 0;
        }
    }

    @AuraEnabled(cacheable=true)
    public static KpiData getKpiData() {
        KpiData kpi = new KpiData();

        // --- Action Required: Status = 'Requested Information' ---
        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WHERE Status = 'Requested Information'
            WITH SECURITY_ENFORCED
        ]) {
            kpi.actionRequired = (Integer) ar.get('cnt');
        }

        // --- Open Claims: Status IN ('New', 'Submitted', 'Draft') ---
        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WHERE Status IN ('New', 'Submitted', 'Draft')
            WITH SECURITY_ENFORCED
        ]) {
            kpi.openClaims = (Integer) ar.get('cnt');
        }

        // --- Under Review ---
        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WHERE Status = 'Under Review'
            WITH SECURITY_ENFORCED
        ]) {
            kpi.underReview = (Integer) ar.get('cnt');
        }

        // --- Approved YTD ---
        Date ytdStart = Date.newInstance(Date.today().year(), 1, 1);
        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WHERE Status = 'Approved'
              AND InitiationDate >= :ytdStart
            WITH SECURITY_ENFORCED
        ]) {
            kpi.approvedYtd = (Integer) ar.get('cnt');
        }

        // --- Approval Rate: Approved / Total (all time) ---
        Integer totalClaims   = 0;
        Integer approvedTotal = 0;

        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WITH SECURITY_ENFORCED
        ]) {
            totalClaims = (Integer) ar.get('cnt');
        }

        for (AggregateResult ar : [
            SELECT COUNT(Id) cnt
            FROM Claim
            WHERE Status = 'Approved'
            WITH SECURITY_ENFORCED
        ]) {
            approvedTotal = (Integer) ar.get('cnt');
        }

        if (totalClaims > 0) {
            kpi.approvalRate = ((Decimal) approvedTotal / totalClaims * 100).setScale(1);
        }

        // avgApprovalDays is static 4.2 per spec
        kpi.avgApprovalDays = 4.2;

        return kpi;
    }
}