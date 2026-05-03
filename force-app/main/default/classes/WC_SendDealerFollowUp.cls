public with sharing class WC_SendDealerFollowUp {

    public class FollowUpRequest {
        @InvocableVariable(label='Claim Id' description='Salesforce 15/18-char record Id. Use Claim Number instead when user provides a Name string.')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='PRIMARY parameter. The auto-generated claim Name string. Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007. Pass exactly as user provided.')
        public String claimNumber;

        @InvocableVariable(required=true label='Questions' description='REQUIRED. The actual question text to send to the dealer — usually the numbered list output from WC_Suggest_Follow_Up_Questions, or the specific items the approver named. Examples: "1. Provide odometer reading at fault. 2. Attach DTC scan output. 3. Send repair invoice."')
        public String questions;

        @InvocableVariable(label='Channel' description='Optional dispatch channel. Pass one of: "Email" (default), "WhatsApp", "Slack", "Portal". Affects audit-comment tag and Warranty_Claim_Event__e payload.')
        public String channel;
    }

    public class FollowUpResponse {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text confirmation. Present verbatim.')
        public String message;

        // Internal-only.
        public Boolean isSuccess;
        public String confirmationMessage;
        public Boolean notificationSent;
        public String errorMessage;
    }

    @InvocableMethod(
        label='Send Dealer Follow-Up'
        description='Records information request on Electra Cars warranty claim for dealer follow-up'
    )
    public static List<FollowUpResponse> sendFollowUp(List<FollowUpRequest> requests) {
        List<FollowUpResponse> results = new List<FollowUpResponse>();
        if (requests == null) {
            return results;
        }
        for (FollowUpRequest req : requests) {
            results.add(processOne(req));
        }
        return results;
    }

    private static FollowUpResponse processOne(FollowUpRequest req) {
        FollowUpResponse one = new FollowUpResponse();
        if ((String.isBlank(req.claimId) && String.isBlank(req.claimNumber)) || String.isBlank(req.questions)) {
            one.isSuccess = false;
            one.errorMessage = 'Claim Id or Claim Number, plus questions, are required.';
            one.message = '⚠️ Need a claim number and questions to send.';
            return one;
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
            one.isSuccess = false;
            one.errorMessage = 'Could not resolve a Claim from the provided Id or Number.';
            one.message = '⚠️ Could not find that claim — please check the claim number.';
            return one;
        }

        List<Claim> rows = [
            SELECT Id, Name, Status, AccountId, Account.Name, EstimatedAmount, Risk_Score__c
            FROM Claim WHERE Id = :claimId LIMIT 1
        ];
        if (rows.isEmpty()) {
            one.isSuccess = false;
            one.errorMessage = 'Claim not found for Electra Cars follow-up.';
            one.message = '⚠️ Claim not found.';
            return one;
        }
        Claim c = rows[0];
        String previousStatus = c.Status;

        String ch = String.isNotBlank(req.channel) ? req.channel : 'Email';
        String existingComments = '';
        Claim cur = [SELECT Approver_Comments__c FROM Claim WHERE Id = :c.Id LIMIT 1];
        if (cur.Approver_Comments__c != null) { existingComments = cur.Approver_Comments__c + '\n---\n'; }

        Claim upd = new Claim(
            Id = c.Id,
            Status = 'Requested Information',
            Approver_Comments__c = existingComments + '[' + ch + ' ' + Datetime.now().format() + '] Approver follow-up:\n' + req.questions
        );
        Database.SaveResult sr = Database.update(upd, false);
        if (!sr.isSuccess()) {
            one.isSuccess = false;
            one.errorMessage = sr.getErrors().isEmpty() ? 'Update failed' : sr.getErrors()[0].getMessage();
            return one;
        }

        Warranty_Claim_Event__e evt = new Warranty_Claim_Event__e(
            Event_Type__c = 'InfoRequested',
            Claim_Id__c = c.Id,
            Claim_Number__c = c.Name,
            Claim_Status__c = 'Requested Information',
            Previous_Status__c = previousStatus,
            Dealer_Account_Id__c = c.AccountId,
            Dealer_Name__c = (c.Account != null) ? c.Account.Name : null,
            Estimated_Amount__c = c.EstimatedAmount,
            Risk_Score__c = c.Risk_Score__c,
            Channel__c = ch
        );
        Database.SaveResult evtResult = EventBus.publish(evt);
        one.notificationSent = evtResult.isSuccess();
        one.isSuccess = true;
        one.confirmationMessage = 'Follow-up logged for ' + c.Name + '. Dealer notification event published'
            + (one.notificationSent ? ' successfully.' : ' (event publish failed — manual follow-up required).');
        one.message = '📨 Follow-Up Sent — Claim ' + c.Name + '\n' +
            '━━━━━━━━━━━━━━━━━━━━━━━\n' +
            'Status: Requested Information\n' +
            'Channel: ' + ch + '\n' +
            (c.Account != null ? 'Dealer: ' + c.Account.Name + '\n' : '') +
            '\nQuestions sent:\n' + req.questions + '\n' +
            (one.notificationSent ? '\n🔔 Notification event published.' : '\n⚠️ Notification event did not publish.');
        return one;
    }
}