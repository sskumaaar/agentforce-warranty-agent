public with sharing class WC_ClaimDecision {

    private static final Set<String> VALID_ACTIONS = new Set<String>{
        'Approve', 'Reject', 'RequestInfo', 'Escalate', 'AddNote'
    };

    private static final Map<String, String> ACTION_TO_COMMENT_TYPE = new Map<String, String>{
        'Approve' => 'Approval',
        'Reject' => 'Denial',
        'RequestInfo' => 'RequestInfo',
        'Escalate' => 'Escalation',
        'AddNote' => 'InternalNote'
    };

    public class Input {
        @InvocableVariable(required=true label='Claim Id')
        public String claimId;

        @InvocableVariable(required=true label='Action' description='Approve, Reject, or RequestInfo')
        public String action;

        @InvocableVariable(label='Comments' description='Approver comments or follow-up request details')
        public String comments;

        @InvocableVariable(label='Rejection Reason' description='Required when action is Reject')
        public String rejectionReason;

        // [v22.3] 3 C's of repair-order audit trail (Concern → Cause → Correction).
        // Engine accepts both as optional and stamps an auto-decided fallback when
        // the controller didn't pre-validate. The LWC controller enforces "Cause
        // required" for human-driven Approve actions before reaching here.
        @InvocableVariable(label='Root Cause' description='Why the part failed. Persists to Claim.RootCause__c.')
        public String rootCause;

        @InvocableVariable(label='Correction Description' description='What was/will be done to fix. Persists to Claim.CorrectionDescription__c.')
        public String correction;
    }

    public class Output {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Claim Number')
        public String claimNumber;

        @InvocableVariable(label='New Status')
        public String newStatus;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='Claim Decision' description='Approve, reject, or request info on a warranty claim with full audit trail')
    public static List<Output> processDecision(List<Input> inputs) {
        List<Output> results = new List<Output>();

        Map<Id, Input> inputsByClaimId = new Map<Id, Input>();
        for (Input inp : inputs) {
            if (String.isNotBlank(inp.claimId)) {
                try { inputsByClaimId.put(inp.claimId, inp); } catch (Exception e) { /* invalid Id */ }
            }
        }

        Map<Id, Claim> claimsMap = new Map<Id, Claim>();
        if (!inputsByClaimId.isEmpty()) {
            claimsMap = new Map<Id, Claim>([
                SELECT Id, Name, Status, StatusCode, EstimatedAmount,
                       ApprovedBy__c, RejectedBy__c, ApprovalDate__c,
                       Conversation_Log__c
                FROM Claim WHERE Id IN :inputsByClaimId.keySet()
            ]);
        }

        List<Claim> toUpdate = new List<Claim>();
        List<Integer> updateResultIndices = new List<Integer>();

        for (Input inp : inputs) {
            Output out = new Output();

            if (String.isBlank(inp.claimId) || String.isBlank(inp.action)) {
                out.success = false;
                out.message = 'Claim Id and Action are required.';
                results.add(out);
                continue;
            }

            if (!VALID_ACTIONS.contains(inp.action)) {
                out.success = false;
                out.message = 'Invalid action "' + inp.action + '". Use Approve, Reject, or RequestInfo.';
                results.add(out);
                continue;
            }

            Claim c = claimsMap.get(inp.claimId);
            if (c == null) {
                out.success = false;
                out.message = 'Claim not found with Id: ' + inp.claimId;
                results.add(out);
                continue;
            }

            out.claimNumber = c.Name;

            if (inp.action == 'Reject' && String.isBlank(inp.rejectionReason)) {
                out.success = false;
                out.message = 'Rejection reason is mandatory. Please provide a reason for denying claim ' + c.Name + '.';
                results.add(out);
                continue;
            }

            if (inp.action == 'Approve' && (c.Status == 'Approved' || c.StatusCode == 'Approved')) {
                out.success = false;
                out.newStatus = c.Status;
                out.message = 'Claim ' + c.Name + ' is already approved.';
                results.add(out);
                continue;
            }

            if (inp.action == 'Reject' && (c.Status == 'Denied' || c.StatusCode == 'Denied')) {
                out.success = false;
                out.newStatus = c.Status;
                out.message = 'Claim ' + c.Name + ' is already denied.';
                results.add(out);
                continue;
            }

            Claim updateClaim = new Claim(Id = c.Id);

            // [Issue 2] Mirror every OEM-side comment into the conversation log so
            // the dealer can see the full back-and-forth history. We append rather
            // than overwrite so multi-round Requested Information loops are preserved.
            String convoBefore = c.Conversation_Log__c;

            if (inp.action == 'Approve') {
                updateClaim.Status = 'Approved';
                updateClaim.ApprovedBy__c = UserInfo.getUserId();
                updateClaim.ApprovalDate__c = Datetime.now();
                updateClaim.Approver_Comments__c = inp.comments;
                // [v22.3] Persist the 3 C's audit trail. If the caller didn't
                // supply a Cause (e.g. flow-driven auto-approve), stamp a clear
                // marker so the field is never blank on an approved claim.
                updateClaim.RootCause__c = String.isNotBlank(inp.rootCause)
                    ? inp.rootCause
                    : 'Auto-decided by Atlas Triage';
                if (String.isNotBlank(inp.correction)) {
                    updateClaim.CorrectionDescription__c = inp.correction;
                }
                if (!String.isBlank(inp.comments)) {
                    updateClaim.Conversation_Log__c = ClaimConversationService.appendEntry(
                        convoBefore, ClaimConversationService.ROLE_OEM, null,
                        '✅ Approved — ' + inp.comments
                    );
                }
                out.newStatus = 'Approved';
                out.message = 'Claim ' + c.Name + ' has been APPROVED. The dealer will be notified.';
            } else if (inp.action == 'Reject') {
                updateClaim.Status = 'Denied';
                updateClaim.RejectedBy__c = UserInfo.getUserId();
                updateClaim.ApprovalDate__c = Datetime.now();
                updateClaim.RejectionReason__c = inp.rejectionReason;
                updateClaim.Approver_Comments__c = inp.comments;
                String denyBody = '🚫 Denied — ' + inp.rejectionReason
                    + (String.isBlank(inp.comments) ? '' : '\n' + inp.comments);
                updateClaim.Conversation_Log__c = ClaimConversationService.appendEntry(
                    convoBefore, ClaimConversationService.ROLE_OEM, null, denyBody
                );
                out.newStatus = 'Denied';
                out.message = 'Claim ' + c.Name + ' has been DENIED. Reason: ' + inp.rejectionReason + '. The dealer will be notified.';
            } else if (inp.action == 'RequestInfo') {
                updateClaim.Status = 'Requested Information';
                updateClaim.Approver_Comments__c = inp.comments;
                if (!String.isBlank(inp.comments)) {
                    updateClaim.Conversation_Log__c = ClaimConversationService.appendEntry(
                        convoBefore, ClaimConversationService.ROLE_OEM, null,
                        '❓ Requested information — ' + inp.comments
                    );
                }
                out.newStatus = 'Requested Information';
                out.message = 'Follow-up request sent for claim ' + c.Name + '. The dealer will be notified. Claim is on hold pending response.';
            } else if (inp.action == 'Escalate') {
                updateClaim.Approver_Comments__c = 'ESCALATED: ' + (inp.comments != null ? inp.comments : '');
                updateClaim.Conversation_Log__c = ClaimConversationService.appendEntry(
                    convoBefore, ClaimConversationService.ROLE_OEM, null,
                    '⚡ Escalated' + (String.isBlank(inp.comments) ? '' : ' — ' + inp.comments)
                );
                out.newStatus = c.Status;
                out.message = 'Claim ' + c.Name + ' has been escalated. Note added to audit trail.';
            } else if (inp.action == 'AddNote') {
                updateClaim.Approver_Comments__c = inp.comments;
                if (!String.isBlank(inp.comments)) {
                    updateClaim.Conversation_Log__c = ClaimConversationService.appendEntry(
                        convoBefore, ClaimConversationService.ROLE_OEM, null,
                        '📝 ' + inp.comments
                    );
                }
                out.newStatus = c.Status;
                out.message = 'Internal note added to claim ' + c.Name + '.';
            }

            toUpdate.add(updateClaim);
            updateResultIndices.add(results.size());
            out.success = true;
            results.add(out);
        }

        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> saveResults = Database.update(toUpdate, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (!saveResults[i].isSuccess()) {
                    Output out = results[updateResultIndices[i]];
                    out.success = false;
                    out.message = 'Update failed: ' + saveResults[i].getErrors()[0].getMessage();
                }
            }
        }

        List<WC_Claim_Comment__c> comments = new List<WC_Claim_Comment__c>();
        String userName = UserInfo.getName();
        for (Input inp : inputs) {
            if (String.isBlank(inp.claimId) || String.isBlank(inp.comments)) continue;
            String cType = ACTION_TO_COMMENT_TYPE.get(inp.action);
            if (cType == null) continue;
            try {
                comments.add(new WC_Claim_Comment__c(
                    Claim__c = inp.claimId,
                    Body__c = inp.comments,
                    Author_Name__c = userName,
                    Comment_Type__c = cType
                ));
            } catch (Exception e) { /* skip invalid IDs */ }
        }
        if (!comments.isEmpty()) {
            Database.insert(comments, false);
        }

        return results;
    }
}