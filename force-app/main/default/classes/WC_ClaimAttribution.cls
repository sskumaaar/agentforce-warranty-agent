/**
 * Single source of truth for the human-readable "decided by" attribution on a
 * Claim. Auto-approve and auto-deny flows leave ApprovedBy__c / RejectedBy__c
 * blank on purpose — meaning "no human." We resolve that blank to the branded
 * label "Atlas AI Triage" so the dealer and approver UIs can confidently show
 * who completed the claim.
 *
 * This class only READS the lookup names — caller is responsible for ensuring
 * Claim.ApprovedBy__r.Name and Claim.RejectedBy__r.Name are part of the SOQL
 * SELECT. If the lookup wasn't queried, we fall back to AI_TRIAGE_LABEL.
 */
public with sharing class WC_ClaimAttribution {

    public static final String AI_TRIAGE_LABEL = 'Atlas AI Triage';

    private static final Set<String> FINAL_STATUSES = new Set<String>{
        'Approved', 'Denied', 'Rejected', 'Settled', 'Closed'
    };

    /**
     * @return human display name (real user name or 'Atlas AI Triage') for a
     *         decided claim, or null when the claim isn't yet decided.
     */
    public static String decidedByDisplay(Claim c) {
        if (c == null || c.Status == null) return null;
        if (!FINAL_STATUSES.contains(c.Status)) return null;

        String fromApprover = safeUserName(c, 'ApprovedBy__c', 'ApprovedBy__r');
        if (String.isNotBlank(fromApprover)) return fromApprover;

        String fromRejecter = safeUserName(c, 'RejectedBy__c', 'RejectedBy__r');
        if (String.isNotBlank(fromRejecter)) return fromRejecter;

        return AI_TRIAGE_LABEL;
    }

    /**
     * @return true when the decision was made by automation (no User stamped).
     *         UI can use this to render with a special AI badge.
     */
    public static Boolean isAutoTriage(Claim c) {
        if (c == null || c.Status == null) return false;
        if (!FINAL_STATUSES.contains(c.Status)) return false;

        String fromApprover = safeUserName(c, 'ApprovedBy__c', 'ApprovedBy__r');
        if (String.isNotBlank(fromApprover)) return false;

        String fromRejecter = safeUserName(c, 'RejectedBy__c', 'RejectedBy__r');
        if (String.isNotBlank(fromRejecter)) return false;

        return true;
    }

    /**
     * Tolerant accessor: if the caller's SOQL didn't traverse the User lookup,
     * c.ApprovedBy__r is null and we silently degrade rather than throwing.
     */
    private static String safeUserName(Claim c, String idField, String relField) {
        try {
            Object idVal = c.get(idField);
            if (idVal == null) return null;
            SObject userObj = c.getSObject(relField);
            if (userObj == null) return null;
            Object nameVal = userObj.get('Name');
            return nameVal == null ? null : String.valueOf(nameVal);
        } catch (Exception e) {
            return null;
        }
    }
}