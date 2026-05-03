// Read-only generator. Runs without sharing so all approver users can request questions.
public without sharing class WC_FollowUpQuestions {

    public class Inp {
        @InvocableVariable(label='Claim Id' description='Salesforce 15/18-char record Id. Use Claim Number instead when user provides a Name string.')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='PRIMARY parameter. The auto-generated claim Name string. Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007. Pass exactly as user provided.')
        public String claimNumber;
    }

    public class Out {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text follow-up question list. Present verbatim.')
        public String message;

        // Internal-only.
        public String questions;
        public String claimNumber;
    }

    @InvocableMethod(
        label='Suggest Follow-Up Questions'
        description='Builds targeted Electra Cars dealer questions from claim gaps'
    )
    public static List<Out> suggest(List<Inp> inputs) {
        List<Out> results = new List<Out>();
        if (inputs == null) {
            return results;
        }
        for (Inp inp : inputs) {
            Out o = new Out();
            Id resolvedId = null;
            if (String.isNotBlank(inp.claimId)) {
                try { resolvedId = Id.valueOf(inp.claimId.trim()); } catch (Exception e) { resolvedId = null; }
            }
            String lookupName = null;
            if (resolvedId == null && String.isNotBlank(inp.claimNumber)) {
                lookupName = inp.claimNumber.trim();
            }
            if (resolvedId == null && lookupName == null) {
                results.add(o);
                continue;
            }
            List<Claim> rows;
            if (resolvedId != null) {
                rows = [SELECT Name, MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c,
                               Risk_Score__c, AI_Triage_Notes__c, EstimatedAmount
                        FROM Claim WHERE Id = :resolvedId LIMIT 1];
            } else {
                rows = [SELECT Name, MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c,
                               Risk_Score__c, AI_Triage_Notes__c, EstimatedAmount
                        FROM Claim WHERE Name = :lookupName LIMIT 1];
            }
            if (rows.isEmpty()) {
                o.message = '⚠️ Could not find the claim — check the claim number.';
                results.add(o);
                continue;
            }
            Claim c = rows[0];
            o.claimNumber = c.Name;
            List<String> lines = new List<String>();
            lines.add('1. What is the odometer at the time the fault occurred?');
            if (c.MileageAtClaim__c == null) {
                lines.set(0, '1. What is the current odometer reading (mileage was missing on claim ' + c.Name + ')?');
            }
            lines.add('2. Please provide full diagnostic scan output related to the reported fault.');
            if (String.isBlank(c.DiagnosticTroubleCode__c)) {
                lines.add('3. Provide any additional DTC codes observed beyond what was submitted.');
            }
            lines.add('4. When did the symptom first appear (city driving, cold start, highway, etc.)?');
            if (c.Risk_Score__c != null && c.Risk_Score__c > 50) {
                lines.add('5. Attach photos or serial evidence for high-value parts requested on this Electra Cars claim.');
            }
            o.questions = String.join(lines, '\n');
            o.message = '📝 Suggested Follow-Up Questions for ' + c.Name + '\n' +
                '━━━━━━━━━━━━━━━━━━━━━━━\n' +
                o.questions + '\n\n' +
                'Want me to send these to the dealer, edit them, or add more?';
            results.add(o);
        }
        return results;
    }
}