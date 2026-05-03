/**
 * WCDealerClaimsTableController
 * Returns the last 20 Claims with ClaimItem category for the Dealer Claims Table LWC.
 * Uses correct field names per FIELD_NAME_CORRECTIONS_CRITICAL.md:
 *   - Claim.Name           = claim number (auto-number)
 *   - Claim.InitiationDate = filed date (not ClaimDate)
 *   - Claim.Summary        = description (not Description)
 *   - Claim.Severity       = priority (not Priority)
 *   - Claim.EstimatedAmount = amount
 *   - Claim.Risk_Score__c  = AI risk score (custom)
 *   - ClaimItem.ClaimId    = parent claim FK
 *   - ClaimItem.Category   = category field
 */
public with sharing class WCDealerClaimsTableController {

    public class ClaimRow {
        @AuraEnabled public String  claimId         { get; set; }
        @AuraEnabled public String  claimNumber     { get; set; }  // Claim.Name
        @AuraEnabled public String  category        { get; set; }  // from ClaimItem
        @AuraEnabled public String  status          { get; set; }
        @AuraEnabled public Decimal estimatedAmount { get; set; }
        @AuraEnabled public Datetime initiationDate  { get; set; }
        @AuraEnabled public Integer riskScore       { get; set; }
        @AuraEnabled public String  severity        { get; set; }
        @AuraEnabled public String  aiRecommendation{ get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<ClaimRow> getRecentClaims() {
        // Query last 20 claims ordered by InitiationDate desc
        List<Claim> claims = [
            SELECT Id,
                   Name,
                   Status,
                   Severity,
                   Summary,
                   EstimatedAmount,
                   InitiationDate,
                   Risk_Score__c,
                   AI_Recommendation__c,
                   (SELECT Id, Category, Description
                    FROM ClaimItems
                    ORDER BY CreatedDate ASC
                    LIMIT 1)
            FROM Claim
            WITH SECURITY_ENFORCED
            ORDER BY InitiationDate DESC NULLS LAST
            LIMIT 20
        ];

        List<ClaimRow> rows = new List<ClaimRow>();
        for (Claim c : claims) {
            ClaimRow row          = new ClaimRow();
            row.claimId           = c.Id;
            row.claimNumber       = c.Name;
            row.status            = c.Status;
            row.severity          = c.Severity;
            row.estimatedAmount   = c.EstimatedAmount;
            row.initiationDate    = c.InitiationDate;
            row.riskScore         = c.Risk_Score__c != null ? c.Risk_Score__c.intValue() : null;
            row.aiRecommendation  = c.AI_Recommendation__c;

            // Pull category from first ClaimItem if present
            if (!c.ClaimItems.isEmpty()) {
                row.category = c.ClaimItems[0].Category;
            } else {
                row.category = '';
            }
            rows.add(row);
        }
        return rows;
    }
}