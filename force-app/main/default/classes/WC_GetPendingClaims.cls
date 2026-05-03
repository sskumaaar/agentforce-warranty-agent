// Read-only queue list used by the Approver Agent. Runs without sharing so any approver user
// (the team + Amit/Priya/Raj) sees the full pending queue regardless of OWD.
public without sharing class WC_GetPendingClaims {

    private static final Integer SLA_WARNING_DAYS = 3;
    private static final Integer SLA_BREACH_DAYS = 6;

    public class Input {
        @InvocableVariable(label='Status Filter' description='Optional. Pass exactly one of: "New", "Under Review", "Submitted", "Requested Information". Leave blank for ALL pending statuses (default — recommended). Use specific status only when user says "show me only Submitted claims" or "what is in Under Review".')
        public String statusFilter;

        @InvocableVariable(label='Max Results' description='Maximum claims to return. Default 20, max 50. Pass higher when user says "show me all", "give me everything", or "full queue".')
        public Integer maxResults;

        @InvocableVariable(label='Sort Mode' description='Pass "risk" (default — sorts by Risk_Score__c descending, highest risk first) OR "aging" (sorts by InitiationDate ascending, oldest first). Use "aging" when user asks about SLA, oldest, overdue, breach, time-sensitive. Use "risk" (or omit) for "show me queue", "highest risk first", "what needs review".')
        public String sortMode;
    }

    public class Output {
        // ONLY this field is exposed to the agent. Pre-formatted plain-text queue listing.
        @InvocableVariable(label='Response' description='Formatted plain-text pending-queue list. Present verbatim.')
        public String message;

        // Internal-only fields — Apex tests still read these directly, agent never sees them.
        public Boolean claimsFound;
        public Integer totalCount;
        public Decimal totalEstimatedAmount;
        public Integer slaBreachCount;
        public String claimsSummary;
    }

    @InvocableMethod(label='Get Pending Claims' description='Retrieves pending warranty claims sorted by risk or aging for approver review. Includes SLA breach indicator and AI triage notes.')
    public static List<Output> getPendingClaims(List<Input> inputs) {
        List<Output> results = new List<Output>();

        for (Input inp : inputs) {
            results.add(processInput(inp));
        }
        return results;
    }

    private static Output processInput(Input inp) {
        Output out = new Output();
        Integer resultLimit = (inp.maxResults != null && inp.maxResults > 0) ? Math.min(inp.maxResults, 50) : 20;
        String sortMode = (inp.sortMode != null) ? inp.sortMode.trim().toLowerCase() : 'risk';

        try {
            Set<String> pendingStatuses = new Set<String>();
            if (String.isNotBlank(inp.statusFilter)) {
                pendingStatuses.add(inp.statusFilter);
            } else {
                pendingStatuses.addAll(new List<String>{ 'New', 'Under Review', 'Submitted', 'Requested Information' });
            }

            String orderBy = (sortMode == 'aging')
                ? 'InitiationDate ASC NULLS LAST, Risk_Score__c DESC NULLS LAST'
                : 'Risk_Score__c DESC NULLS LAST, InitiationDate ASC';

            String soql =
                'SELECT Id, Name, Status, StatusCode, Severity, Summary, ' +
                       'EstimatedAmount, AccountId, Account.Name, ' +
                       'InitiationDate, Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c, ' +
                       'DealerCode__c, Channel__c, InsuredAssetId ' +
                'FROM Claim ' +
                'WHERE Status IN :pendingStatuses ' +
                'ORDER BY ' + orderBy + ' ' +
                'LIMIT :resultLimit';

            List<Claim> claims = Database.query(soql);

            if (claims.isEmpty()) {
                out.claimsFound = false;
                out.totalCount = 0;
                out.totalEstimatedAmount = 0;
                out.slaBreachCount = 0;
                out.claimsSummary = '';
                out.message = 'No pending claims found. Your review queue is clear.';
                return out;
            }

            Set<Id> assetIds = new Set<Id>();
            for (Claim c : claims) {
                if (c.InsuredAssetId != null) { assetIds.add(c.InsuredAssetId); }
            }

            Map<Id, Vehicle> vehiclesByAsset = new Map<Id, Vehicle>();
            if (!assetIds.isEmpty()) {
                for (Vehicle v : [
                    SELECT Id, AssetId, MakeName, ModelName, ModelYear
                    FROM Vehicle WHERE AssetId IN :assetIds
                ]) {
                    vehiclesByAsset.put(v.AssetId, v);
                }
            }

            Decimal totalAmount = 0;
            Integer slaBreaches = 0;
            List<String> lines = new List<String>();
            Integer idx = 1;
            Date today = Date.today();

            for (Claim c : claims) {
                if (c.EstimatedAmount != null) { totalAmount += c.EstimatedAmount; }

                String riskIcon = getRiskIcon(c.Risk_Score__c);
                Integer score = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : 0;
                String riskLevel = getRiskLevel(score);

                Integer daysPending = 0;
                if (c.InitiationDate != null) {
                    Object raw = c.get('InitiationDate');
                    Date initDate;
                    if (raw instanceof Date) { initDate = (Date) raw; }
                    else if (raw instanceof Datetime) { initDate = ((Datetime) raw).date(); }
                    if (initDate != null) { daysPending = initDate.daysBetween(today); }
                }
                String slaTag = '';
                if (daysPending >= SLA_BREACH_DAYS) { slaTag = ' ⚠️ SLA BREACH'; slaBreaches++; }
                else if (daysPending >= SLA_WARNING_DAYS) { slaTag = ' ⏰ SLA Warning'; }

                Vehicle v = (c.InsuredAssetId != null) ? vehiclesByAsset.get(c.InsuredAssetId) : null;
                String vehicleLabel = (v != null)
                    ? v.ModelYear + ' ' + v.MakeName + ' ' + v.ModelName
                    : 'Vehicle N/A';

                String dealerName = (c.Account != null) ? c.Account.Name : 'Unknown Dealer';
                String amount = (c.EstimatedAmount != null)
                    ? '$' + c.EstimatedAmount.setScale(0).toPlainString() : 'N/A';
                String recommendation = (c.AI_Recommendation__c != null) ? c.AI_Recommendation__c : 'Pending';
                String triage = (c.AI_Triage_Notes__c != null && !c.AI_Triage_Notes__c.equals(''))
                    ? trimTo(c.AI_Triage_Notes__c, 120) : null;

                String line = idx + '. ' + riskIcon + ' ' + c.Name +
                    ' | ' + amount + ' | Risk: ' + score + ' (' + riskLevel + ') | ' + daysPending + 'd pending' + slaTag +
                    '\n   ' + dealerName + ' | ' + vehicleLabel +
                    '\n   Recommendation: ' + recommendation;
                if (triage != null) { line += '\n   Triage: ' + triage; }

                lines.add(line);
                idx++;
            }

            out.claimsFound = true;
            out.totalCount = claims.size();
            out.totalEstimatedAmount = totalAmount;
            out.slaBreachCount = slaBreaches;
            out.claimsSummary = String.join(lines, '\n\n');

            // Build a single rich plain-text message that the agent shows verbatim.
            String header = '📋 Pending Claim Queue (' + claims.size() + ' claim' +
                (claims.size() == 1 ? '' : 's') + ', total $' +
                totalAmount.setScale(0).toPlainString() + ')';
            if (slaBreaches > 0) {
                header += '\n⚠️ ' + slaBreaches + ' SLA breach' + (slaBreaches == 1 ? '' : 'es') + ' — review urgently';
            }
            out.message = header + '\n━━━━━━━━━━━━━━━━━━━━━━━\n\n' + String.join(lines, '\n\n');

        } catch (Exception e) {
            out.claimsFound = false;
            out.totalCount = 0;
            out.totalEstimatedAmount = 0;
            out.slaBreachCount = 0;
            out.claimsSummary = '';
            out.message = 'Error retrieving pending claims: ' + e.getMessage();
        }

        return out;
    }

    private static String trimTo(String s, Integer max) {
        if (s == null) { return null; }
        return (s.length() <= max) ? s : s.substring(0, max - 1) + '…';
    }

    private static String getRiskIcon(Decimal score) {
        if (score == null) { return '⚪'; }
        Integer s = score.intValue();
        if (s >= 80) { return '🔴'; }
        if (s >= 50) { return '🟠'; }
        if (s >= 21) { return '🟡'; }
        return '🟢';
    }

    private static String getRiskLevel(Integer score) {
        if (score >= 80) { return 'Critical'; }
        if (score >= 50) { return 'High'; }
        if (score >= 21) { return 'Medium'; }
        return 'Low';
    }
}