// Read-only "next claim" lookup. Runs without sharing so all approver users see the full queue.
public without sharing class WC_GetNextPendingClaim {

    public class Input {
        @InvocableVariable(label='Sort Mode' description='Pass "risk" (default — highest Risk_Score__c first) OR "aging" (oldest InitiationDate first). Use "aging" when approver wants the oldest pending claim or SLA-priority claim.')
        public String sortMode;

        @InvocableVariable(label='Skip Claim Numbers' description='Optional comma-separated list of claim Names to exclude — used to advance past already-reviewed claims in iterative review. Example: "WC-000362,WC-000363,WC-000364".')
        public String skipClaimNumbers;
    }

    public class Output {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text next-claim summary. Present verbatim.')
        public String message;

        // Internal-only fields (not visible to agent).
        public Boolean found;
        public String claimId;
        public String claimNumber;
        public String status;
        public String dealerName;
        public Decimal estimatedAmount;
        public Decimal riskScore;
        public String aiRecommendation;
        public String aiTriageNotes;
        public Integer daysPending;
    }

    @InvocableMethod(
        label='Get Next Pending Claim'
        description='Returns the next pending claim in the approver queue (top of risk-sorted list, or oldest by aging). Optional skip list for claims already handled in session.'
    )
    public static List<Output> getNext(List<Input> inputs) {
        List<Output> results = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            results.add(processOne(new Input()));
            return results;
        }
        for (Input inp : inputs) {
            results.add(processOne(inp));
        }
        return results;
    }

    private static Output processOne(Input inp) {
        Output out = new Output();
        String sortMode = (inp.sortMode != null) ? inp.sortMode.trim().toLowerCase() : 'risk';
        Set<String> skip = new Set<String>();
        if (String.isNotBlank(inp.skipClaimNumbers)) {
            for (String s : inp.skipClaimNumbers.split(',')) {
                if (String.isNotBlank(s)) { skip.add(s.trim()); }
            }
        }

        Set<String> pendingStatuses = new Set<String>{ 'New', 'Under Review', 'Submitted', 'Requested Information' };
        String orderBy = (sortMode == 'aging')
            ? 'InitiationDate ASC NULLS LAST, Risk_Score__c DESC NULLS LAST'
            : 'Risk_Score__c DESC NULLS LAST, InitiationDate ASC';

        String soql =
            'SELECT Id, Name, Status, EstimatedAmount, AccountId, Account.Name, ' +
                   'Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c, InitiationDate ' +
            'FROM Claim ' +
            'WHERE Status IN :pendingStatuses ';
        if (!skip.isEmpty()) { soql += 'AND Name NOT IN :skip '; }
        soql += 'ORDER BY ' + orderBy + ' LIMIT 1';

        List<Claim> rows = Database.query(soql);
        if (rows.isEmpty()) {
            out.found = false;
            out.message = 'No more pending claims in queue.' + (skip.isEmpty() ? '' : ' (' + skip.size() + ' skipped this session)');
            return out;
        }
        Claim c = rows[0];
        out.found = true;
        out.claimId = c.Id;
        out.claimNumber = c.Name;
        out.status = c.Status;
        out.dealerName = (c.Account != null) ? c.Account.Name : null;
        out.estimatedAmount = c.EstimatedAmount;
        out.riskScore = c.Risk_Score__c;
        out.aiRecommendation = c.AI_Recommendation__c;
        out.aiTriageNotes = c.AI_Triage_Notes__c;
        if (c.InitiationDate != null) {
            Object raw = c.get('InitiationDate');
            Date initDate;
            if (raw instanceof Date) { initDate = (Date) raw; }
            else if (raw instanceof Datetime) { initDate = ((Datetime) raw).date(); }
            if (initDate != null) { out.daysPending = initDate.daysBetween(Date.today()); }
        }
        // Build rich plain-text message with risk icon
        Integer rs = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : 0;
        String riskIcon = '⚪';
        String riskLevel = 'Unknown';
        if (rs >= 80) { riskIcon = '🔴'; riskLevel = 'Critical'; }
        else if (rs >= 50) { riskIcon = '🟠'; riskLevel = 'High'; }
        else if (rs >= 21) { riskIcon = '🟡'; riskLevel = 'Medium'; }
        else if (rs > 0)   { riskIcon = '🟢'; riskLevel = 'Low'; }

        List<String> lines = new List<String>();
        lines.add('▶️ Next Claim: ' + c.Name);
        lines.add('━━━━━━━━━━━━━━━━━━━━━━━');
        lines.add('Status: ' + c.Status);
        lines.add('Risk Score: ' + riskIcon + ' ' + rs + ' / 100 (' + riskLevel + ')');
        if (c.EstimatedAmount != null) {
            lines.add('Estimated Amount: $' + c.EstimatedAmount.setScale(2).toPlainString());
        }
        if (out.dealerName != null) {
            lines.add('Dealer: ' + out.dealerName);
        }
        if (out.daysPending != null) {
            lines.add('Days Pending: ' + out.daysPending);
        }
        if (c.AI_Recommendation__c != null) {
            lines.add('AI Recommendation: ' + c.AI_Recommendation__c);
        }
        if (c.AI_Triage_Notes__c != null && c.AI_Triage_Notes__c != '') {
            String trimmed = c.AI_Triage_Notes__c.length() > 200
                ? c.AI_Triage_Notes__c.substring(0, 197) + '…'
                : c.AI_Triage_Notes__c;
            lines.add('Triage Notes: ' + trimmed.replace('\n', ' / '));
        }
        lines.add('');
        lines.add('Approve, deny, or request more info?');
        out.message = String.join(lines, '\n');
        return out;
    }
}