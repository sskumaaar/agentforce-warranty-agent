// Read-only lookup used by the Approver Agent. Runs without sharing so any approver user
// (Santosh, Piyush, Pooja, Sonal, Amit, Priya, Raj) can see all claims regardless of OWD.
// FLS still applies via the WC_Field_Access permset.
public without sharing class WC_ClaimStatus {

    @InvocableMethod(
        label='Get Claim Status'
        description='Retrieves warranty claim status by claim number, VIN, or dealer account. Returns claim details including status, risk score, and decision.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        try {
            Set<String> claimNumbers = new Set<String>();
            Set<String> vinNumbers = new Set<String>();
            Set<Id> dealerIds = new Set<Id>();

            for (Input inp : inputs) {
                if (String.isNotBlank(inp.claimNumber)) {
                    claimNumbers.add(inp.claimNumber.trim());
                } else if (String.isNotBlank(inp.vinNumber)) {
                    vinNumbers.add(inp.vinNumber.trim());
                } else if (String.isNotBlank(inp.dealerAccountId)) {
                    try {
                        dealerIds.add(Id.valueOf(inp.dealerAccountId.trim()));
                    } catch (StringException ex) {
                        // Invalid ID format — handled during output assembly
                    }
                }
            }

            Map<String, List<Claim>> claimsByNumber = new Map<String, List<Claim>>();
            if (!claimNumbers.isEmpty()) {
                for (Claim c : [
                    SELECT Id, Name, Status, StatusCode, Severity, Summary,
                           AccountId, Account.Name,
                           EstimatedAmount, InitiationDate, FinalizedDate, IsClosed,
                           Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c,
                           Approver_Comments__c, Channel__c
                    FROM Claim
                    WHERE Name IN :claimNumbers
                ]) {
                    if (!claimsByNumber.containsKey(c.Name)) {
                        claimsByNumber.put(c.Name, new List<Claim>());
                    }
                    claimsByNumber.get(c.Name).add(c);
                }
            }

            Map<String, Id> vinToVehicleId = new Map<String, Id>();
            if (!vinNumbers.isEmpty()) {
                for (Vehicle v : [
                    SELECT Id, VehicleIdentificationNumber
                    FROM Vehicle
                    WHERE VehicleIdentificationNumber IN :vinNumbers
                ]) {
                    vinToVehicleId.put(v.VehicleIdentificationNumber, v.Id);
                }
            }

            Map<Id, List<Claim>> claimsByVehicleId = new Map<Id, List<Claim>>();
            Set<Id> vehicleIds = new Set<Id>(vinToVehicleId.values());
            if (!vehicleIds.isEmpty()) {
                Set<Id> claimIds = new Set<Id>();
                Map<Id, Id> claimToVehicle = new Map<Id, Id>();
                for (ClaimItem ci : [SELECT ClaimId, VehicleId FROM ClaimItem WHERE VehicleId IN :vehicleIds]) {
                    claimIds.add(ci.ClaimId);
                    claimToVehicle.put(ci.ClaimId, ci.VehicleId);
                }
                if (!claimIds.isEmpty()) {
                    for (Claim c : [
                        SELECT Id, Name, Status, StatusCode, Severity, Summary,
                               AccountId, Account.Name,
                               EstimatedAmount, InitiationDate, FinalizedDate, IsClosed,
                               Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c,
                               Approver_Comments__c, Channel__c
                        FROM Claim
                        WHERE Id IN :claimIds
                        ORDER BY InitiationDate DESC
                    ]) {
                        Id vehicleId = claimToVehicle.get(c.Id);
                        if (!claimsByVehicleId.containsKey(vehicleId)) {
                            claimsByVehicleId.put(vehicleId, new List<Claim>());
                        }
                        claimsByVehicleId.get(vehicleId).add(c);
                    }
                }
            }

            Map<Id, List<Claim>> claimsByAccountId = new Map<Id, List<Claim>>();
            if (!dealerIds.isEmpty()) {
                for (Claim c : [
                    SELECT Id, Name, Status, StatusCode, Severity, Summary,
                           AccountId, Account.Name,
                           EstimatedAmount, InitiationDate, FinalizedDate, IsClosed,
                           Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c,
                           Approver_Comments__c, Channel__c
                    FROM Claim
                    WHERE AccountId IN :dealerIds
                    ORDER BY InitiationDate DESC
                    LIMIT 50
                ]) {
                    if (!claimsByAccountId.containsKey(c.AccountId)) {
                        claimsByAccountId.put(c.AccountId, new List<Claim>());
                    }
                    claimsByAccountId.get(c.AccountId).add(c);
                }
            }

            for (Input inp : inputs) {
                Output out = new Output();
                List<Claim> matchingClaims = null;

                if (String.isNotBlank(inp.claimNumber)) {
                    matchingClaims = claimsByNumber.get(inp.claimNumber.trim());
                } else if (String.isNotBlank(inp.vinNumber)) {
                    Id vehicleId = vinToVehicleId.get(inp.vinNumber.trim());
                    if (vehicleId != null) {
                        matchingClaims = claimsByVehicleId.get(vehicleId);
                    }
                } else if (String.isNotBlank(inp.dealerAccountId)) {
                    try {
                        Id dealerId = Id.valueOf(inp.dealerAccountId.trim());
                        matchingClaims = claimsByAccountId.get(dealerId);
                    } catch (StringException ex) {
                        out.found = false;
                        out.message = 'Invalid dealer account ID format';
                        outputs.add(out);
                        continue;
                    }
                } else {
                    out.found = false;
                    out.message = 'Please provide a claim number, VIN, or dealer account';
                    outputs.add(out);
                    continue;
                }

                if (matchingClaims == null || matchingClaims.isEmpty()) {
                    out.found = false;
                    out.message = 'No claims found';
                    outputs.add(out);
                    continue;
                }

                Claim primary = matchingClaims[0];
                out.found = true;
                out.claimId = primary.Id;
                out.claimNumber = primary.Name;
                out.status = primary.Status;
                out.riskScore = primary.Risk_Score__c;
                out.aiRecommendation = primary.AI_Recommendation__c;
                out.submittedDate = primary.InitiationDate;
                out.approverComments = primary.Approver_Comments__c;
                out.totalClaimsFound = matchingClaims.size();

                if (matchingClaims.size() > 1) {
                    List<String> parts = new List<String>();
                    for (Claim c : matchingClaims) {
                        parts.add(c.Name + ' (' + c.Status + ')');
                    }
                    out.claimsSummary = String.join(parts, ', ');
                }

                out.message = buildRichSummary(primary, matchingClaims.size());

                outputs.add(out);
            }
        } catch (Exception e) {
            outputs.clear();
            for (Input inp : inputs) {
                Output out = new Output();
                out.found = false;
                out.message = 'Error retrieving claim status: ' + e.getMessage();
                outputs.add(out);
            }
        }

        return outputs;
    }

    public class Input {
        @InvocableVariable(label='Claim Number'
            description='The auto-generated claim number (Name field) to look up. Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007, CLM-00042. Pass this string EXACTLY as the user provided. NOT a 15/18-character Salesforce record ID. This is the most common parameter — use it for any "show me claim X" / "review WC-XXX" / "details on claim Y" utterance.')
        public String claimNumber;

        @InvocableVariable(label='VIN Number'
            description='Vehicle Identification Number. Use ONLY if user provided a VIN (17-char) instead of a claim number. Example: 1ELEC2024BOLT003.')
        public String vinNumber;

        @InvocableVariable(label='Dealer Account Id'
            description='Salesforce Account.Id (15/18-char) of a dealer. RARELY needed — use claimNumber instead for single-claim lookups.')
        public String dealerAccountId;
    }

    public class Output {
        // ONLY this field is exposed to the agent runtime. The action returns a single
        // pre-formatted plain-text response that the agent shows verbatim — no LLM templating,
        // no other fields dumped to the chat UI.
        @InvocableVariable(label='Response' description='Formatted plain-text response. Present verbatim to the user.')
        public String message;

        // Internal-only fields — public so Apex tests / chained Apex code can read them,
        // but NOT @InvocableVariable so the agent never sees or echoes them.
        public Boolean found;
        public String claimId;
        public String claimNumber;
        public String status;
        public Decimal riskScore;
        public String aiRecommendation;
        public String vehicleName;
        public Datetime submittedDate;
        public String approverComments;
        public Integer totalClaimsFound;
        public String claimsSummary;
    }

    private static String buildRichSummary(Claim c, Integer matchCount) {
        String riskIcon = '⚪';
        Integer rs = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : 0;
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

        // Plain-text format with line breaks + emoji icons.
        // No Markdown syntax — Salesforce Agent UI does not render Markdown.
        List<String> lines = new List<String>();
        lines.add(statusIcon + ' Claim ' + c.Name);
        lines.add('━━━━━━━━━━━━━━━━━━━━━━━');
        lines.add('Status: ' + c.Status);
        if (c.Risk_Score__c != null) {
            lines.add('Risk Score: ' + riskIcon + ' ' + rs + ' / 100 (' + riskLevel + ')');
        }
        if (c.AI_Recommendation__c != null) {
            lines.add('AI Recommendation: ' + c.AI_Recommendation__c);
        }
        if (c.EstimatedAmount != null) {
            lines.add('Estimated Amount: $' + c.EstimatedAmount.setScale(2).toPlainString());
        }
        if (c.Account != null && c.Account.Name != null) {
            lines.add('Dealer: ' + c.Account.Name);
        }
        if (c.InitiationDate != null) {
            lines.add('Submitted: ' + String.valueOf(c.InitiationDate));
        }
        if (c.Severity != null) {
            lines.add('Severity: ' + c.Severity);
        }
        if (c.Approver_Comments__c != null) {
            String trimmed = c.Approver_Comments__c.length() > 200
                ? c.Approver_Comments__c.substring(0, 197) + '…'
                : c.Approver_Comments__c;
            lines.add('Approver Notes: ' + trimmed.replace('\n', ' / '));
        }
        if (matchCount > 1) {
            lines.add('');
            lines.add('(' + matchCount + ' claims matched — showing primary)');
        }
        return String.join(lines, '\n');
    }
}