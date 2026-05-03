public with sharing class WC_ApproveRejectClaim {

    public class DecisionRequest {
        @InvocableVariable(label='Claim Id' description='Salesforce 15/18-char record Id of the claim. Use Claim Number instead if user provided a Name like WC-000362.')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='The auto-generated claim Name like WC-000362, WC-TEST-SEED-002, P12-AUTO-003, CLM-00042. PRIMARY parameter — use this for any approve/deny utterance with a claim number string. Pass exactly as user provided.')
        public String claimNumber;

        @InvocableVariable(required=true label='Decision' description='REQUIRED. Pass either "Approve" or "Reject" (case-insensitive). Apex tolerates "Approved", "Rejected", "Deny", "Denied" but canonical values are "Approve" and "Reject". Pick "Approve" for any approve/accept/finalize utterance, "Reject" for any deny/decline/reject utterance.')
        public String decision;

        @InvocableVariable(required=true label='Comments' description='REQUIRED. The reason or rationale for the decision — captured in the audit trail (Approver_Comments__c). Examples: "Parts verified, dealer documentation complete", "Warranty expired before claim date", "Fraud pattern: duplicate VIN flagged". Always extract the reason from the user utterance; if missing, ask the approver to provide one.')
        public String comments;

        @InvocableVariable(label='Approved Amount' description='Optional partial-approval amount in DOLLARS (Decimal). Use ONLY when approver gives a specific dollar amount like "approve at $1500" or "approve $800". Example: 1500. NEVER use this for percentage like "50%" - use Approved Percent instead. Sets ApprovedAmount field on the Claim. If both percent and amount omitted, the full claim amount is approved.')
        public Decimal approvedAmount;

        @InvocableVariable(label='Approved Percent' description='Optional partial-approval as a PERCENTAGE of EstimatedAmount (Decimal 0-100). Use this when approver says "approve 50%", "approve at 75 percent", "partial 30%", "approve half" (=50), "approve quarter" (=25). Example: pass 50 for "approve 50%". Apex will compute ApprovedAmount = EstimatedAmount * percent / 100. NEVER pass this as a dollar amount. If both percent and amount given, percent takes priority.')
        public Decimal approvedPercent;

        @InvocableVariable(label='Channel' description='Optional source channel attribution: "Agentforce" (default), "Slack", "Web", "Email", "WhatsApp". Used for Warranty_Claim_Event__e payload routing.')
        public String channel;
    }

    public class DecisionResponse {
        // ONLY this field is exposed to the agent. Pre-formatted plain-text confirmation.
        @InvocableVariable(label='Response' description='Formatted plain-text decision confirmation. Present verbatim.')
        public String message;

        // Internal-only fields — visible to Apex tests, NOT to the agent.
        public Boolean isSuccess;
        public String claimNumber;
        public String newStatus;
        public Boolean notificationSent;
        public String errorMessage;
    }

    @InvocableMethod(
        label='Approve or Reject Claim'
        description='Approve or deny Electra Cars warranty claim with audit fields'
    )
    public static List<DecisionResponse> decide(List<DecisionRequest> requests) {
        List<DecisionResponse> results = new List<DecisionResponse>();
        if (requests == null) {
            return results;
        }
        for (DecisionRequest req : requests) {
            results.add(processOne(req));
        }
        return results;
    }

    private static DecisionResponse processOne(DecisionRequest req) {
        DecisionResponse out = new DecisionResponse();
        out.notificationSent = false;

        if ((String.isBlank(req.claimId) && String.isBlank(req.claimNumber)) || String.isBlank(req.decision) || String.isBlank(req.comments)) {
            out.isSuccess = false;
            out.errorMessage = 'Claim Id or Claim Number, plus decision and comments are required.';
            out.message = '⚠️ Missing required input. Please provide a claim number, a decision (Approve/Deny), and a reason.';
            return out;
        }

        String d = req.decision.trim().toLowerCase();
        if (d == 'approved') { d = 'approve'; }
        if (d == 'rejected' || d == 'deny' || d == 'denied') { d = 'reject'; }
        if (d != 'approve' && d != 'reject') {
            out.isSuccess = false;
            out.errorMessage = 'Decision must be Approve or Reject.';
            return out;
        }

        Id claimId;
        if (String.isNotBlank(req.claimId)) {
            try { claimId = Id.valueOf(req.claimId.trim()); } catch (Exception e) { claimId = null; }
        }
        if (claimId == null && String.isNotBlank(req.claimNumber)) {
            List<Claim> byName = [SELECT Id FROM Claim WHERE Name = :req.claimNumber.trim() LIMIT 1];
            if (!byName.isEmpty()) claimId = byName[0].Id;
        }
        if (claimId == null) {
            out.isSuccess = false;
            out.errorMessage = 'Could not resolve a Claim from the provided Id or Number.';
            return out;
        }

        List<Claim> rows = [
            SELECT Id, Name, Status, StatusCode, AccountId, Account.Name,
                   EstimatedAmount, Risk_Score__c, Conversation_Log__c
            FROM Claim WHERE Id = :claimId LIMIT 1
        ];
        if (rows.isEmpty()) {
            out.isSuccess = false;
            out.errorMessage = 'Claim not found.';
            return out;
        }
        Claim c = rows[0];
        out.claimNumber = c.Name;

        if (d == 'approve' && (c.Status == 'Approved' || c.StatusCode == 'Approved')) {
            out.isSuccess = false;
            out.newStatus = c.Status;
            out.errorMessage = 'Claim already approved.';
            out.message = '⚠️ Claim ' + c.Name + ' is already Approved. Decisions are final and audited. To add context, you can append a comment on the record.';
            return out;
        }
        if (d == 'reject' && (c.Status == 'Denied' || c.StatusCode == 'Denied')) {
            out.isSuccess = false;
            out.newStatus = c.Status;
            out.errorMessage = 'Claim already denied.';
            out.message = '⚠️ Claim ' + c.Name + ' is already Denied. Decisions are final and audited.';
            return out;
        }

        // [Issue 2] Append OEM decision to conversation log so dealer sees full history
        String convoBefore = c.Conversation_Log__c;

        Decimal computedApprovedAmount = req.approvedAmount;
        if (d == 'approve' && req.approvedPercent != null && req.approvedPercent > 0) {
            Decimal pct = req.approvedPercent;
            if (pct > 100) { pct = 100; }
            if (c.EstimatedAmount != null) {
                computedApprovedAmount = (c.EstimatedAmount * pct / 100).setScale(2);
            }
        }

        Claim upd = new Claim(Id = c.Id);
        if (d == 'approve') {
            upd.Status = 'Approved';
            upd.ApprovedBy__c = UserInfo.getUserId();
            upd.ApprovalDate__c = Datetime.now();
            upd.Approver_Comments__c = req.comments;
            if (computedApprovedAmount != null) {
                upd.ApprovedAmount = computedApprovedAmount;
            }
            if (!String.isBlank(req.comments)) {
                String approvalNote = '✅ Approved — ' + req.comments;
                if (req.approvedPercent != null) {
                    approvalNote += ' (' + req.approvedPercent.setScale(0) + '% = $' +
                        (computedApprovedAmount != null ? computedApprovedAmount.setScale(2).toPlainString() : '?') + ')';
                } else if (req.approvedAmount != null) {
                    approvalNote += ' ($' + req.approvedAmount.setScale(2).toPlainString() + ')';
                }
                upd.Conversation_Log__c = ClaimConversationService.appendEntry(
                    convoBefore, ClaimConversationService.ROLE_OEM, null, approvalNote
                );
            }
            out.newStatus = 'Approved';
        } else {
            upd.Status = 'Denied';
            upd.RejectedBy__c = UserInfo.getUserId();
            upd.ApprovalDate__c = Datetime.now();
            upd.RejectionReason__c = req.comments;
            upd.Approver_Comments__c = req.comments;
            upd.Conversation_Log__c = ClaimConversationService.appendEntry(
                convoBefore, ClaimConversationService.ROLE_OEM, null,
                '🚫 Denied — ' + (String.isBlank(req.comments) ? 'no reason provided' : req.comments)
            );
            out.newStatus = 'Denied';
        }

        Database.SaveResult sr = Database.update(upd, false);
        if (!sr.isSuccess()) {
            out.isSuccess = false;
            out.errorMessage = sr.getErrors().isEmpty() ? 'Update failed' : sr.getErrors()[0].getMessage();
            return out;
        }

        Warranty_Claim_Event__e evt = new Warranty_Claim_Event__e(
            Event_Type__c = (d == 'approve') ? 'Approved' : 'Denied',
            Claim_Id__c = c.Id,
            Claim_Number__c = c.Name,
            Claim_Status__c = out.newStatus,
            Previous_Status__c = c.Status,
            Dealer_Account_Id__c = c.AccountId,
            Dealer_Name__c = (c.Account != null) ? c.Account.Name : null,
            Estimated_Amount__c = c.EstimatedAmount,
            Risk_Score__c = c.Risk_Score__c,
            Channel__c = String.isNotBlank(req.channel) ? req.channel : 'Agentforce'
        );
        Database.SaveResult evtResult = EventBus.publish(evt);
        out.notificationSent = evtResult.isSuccess();
        out.isSuccess = true;

        out.message = buildSuccessMessage(c, d, req, computedApprovedAmount, out.notificationSent);
        return out;
    }

    private static String buildSuccessMessage(Claim c, String d, DecisionRequest req, Decimal computedAmount, Boolean notified) {
        // Plain text with line breaks + emoji. No Markdown — Salesforce Agent UI doesn't render it.
        List<String> lines = new List<String>();
        if (d == 'approve') {
            lines.add('✅ Claim ' + c.Name + ' Approved');
            lines.add('━━━━━━━━━━━━━━━━━━━━━━━');
            lines.add('Status: Approved');
            if (req.approvedPercent != null) {
                lines.add('Approved %: ' + req.approvedPercent.setScale(0) + '%');
                if (computedAmount != null) {
                    lines.add('Approved Amount: $' + computedAmount.setScale(2).toPlainString() +
                        (c.EstimatedAmount != null ? ' (of $' + c.EstimatedAmount.setScale(2).toPlainString() + ' claimed)' : ''));
                }
            } else if (req.approvedAmount != null) {
                lines.add('Approved Amount: $' + req.approvedAmount.setScale(2).toPlainString() +
                    (c.EstimatedAmount != null ? ' (of $' + c.EstimatedAmount.setScale(2).toPlainString() + ' claimed)' : ''));
            } else if (c.EstimatedAmount != null) {
                lines.add('Approved Amount: $' + c.EstimatedAmount.setScale(2).toPlainString() + ' (full claim)');
            }
            lines.add('Reason: ' + (req.comments != null ? req.comments : '—'));
            if (c.Account != null && c.Account.Name != null) {
                lines.add('Dealer: ' + c.Account.Name);
            }
            lines.add('');
            lines.add(notified
                ? '🔔 Dealer notification event published.'
                : '⚠️ Decision saved, but dealer notification event did not publish.');
        } else {
            lines.add('🚫 Claim ' + c.Name + ' Denied');
            lines.add('━━━━━━━━━━━━━━━━━━━━━━━');
            lines.add('Status: Denied');
            lines.add('Reason: ' + (req.comments != null ? req.comments : '—'));
            if (c.Account != null && c.Account.Name != null) {
                lines.add('Dealer: ' + c.Account.Name);
            }
            if (c.EstimatedAmount != null) {
                lines.add('Claimed Amount: $' + c.EstimatedAmount.setScale(2).toPlainString());
            }
            lines.add('');
            lines.add(notified
                ? '🔔 Dealer notification event published.'
                : '⚠️ Decision saved, but dealer notification event did not publish.');
        }
        lines.add('');
        lines.add('Audit trail updated. Decisions are final.');
        return String.join(lines, '\n');
    }
}