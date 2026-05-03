// Read-only attachment lookup. Runs without sharing so all approver users see attachments.
public without sharing class WC_GetClaimAttachments {

    public class Input {
        @InvocableVariable(label='Claim Id' description='Salesforce 15/18-char record Id of the claim. Use Claim Number instead if user provided a Name string.')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='PRIMARY parameter. The auto-generated claim Name string. Examples: WC-000362, WC-TEST-SEED-003, P12-AUTO-007, CLM-00042. Pass exactly as user provided.')
        public String claimNumber;
    }

    public class Output {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text attachment list. Present verbatim.')
        public String message;

        // Internal-only.
        public Boolean found;
        public Integer fileCount;
        public String claimNumber;
        public String filesSummary;
    }

    @InvocableMethod(
        label='Get Claim Attachments'
        description='Lists files (photos, invoices, diagnostic scans) attached to an Electra Cars warranty claim.'
    )
    public static List<Output> getAttachments(List<Input> inputs) {
        List<Output> results = new List<Output>();
        if (inputs == null) { return results; }
        for (Input inp : inputs) {
            results.add(processOne(inp));
        }
        return results;
    }

    private static Output processOne(Input inp) {
        Output out = new Output();
        Id claimId;
        if (String.isNotBlank(inp.claimId)) {
            try { claimId = Id.valueOf(inp.claimId.trim()); } catch (Exception e) { claimId = null; }
        }
        if (claimId == null && String.isNotBlank(inp.claimNumber)) {
            List<Claim> rows = [SELECT Id, Name FROM Claim WHERE Name = :inp.claimNumber.trim() LIMIT 1];
            if (!rows.isEmpty()) { claimId = rows[0].Id; out.claimNumber = rows[0].Name; }
        }
        if (claimId == null) {
            out.found = false;
            out.fileCount = 0;
            out.message = '⚠️ Need a claim number — e.g. "show attachments for WC-001227".';
            return out;
        }
        if (out.claimNumber == null) {
            List<Claim> rows = [SELECT Name FROM Claim WHERE Id = :claimId LIMIT 1];
            if (!rows.isEmpty()) { out.claimNumber = rows[0].Name; }
        }

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :claimId
            LIMIT 50
        ];
        if (links.isEmpty()) {
            out.found = false;
            out.fileCount = 0;
            out.message = '📎 Attachments — ' + out.claimNumber + '\n━━━━━━━━━━━━━━━━━━━━━━━\n(no files attached)';
            return out;
        }
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) { docIds.add(l.ContentDocumentId); }

        List<ContentVersion> versions = [
            SELECT Id, Title, FileType, ContentSize, FileExtension, ContentDocumentId, CreatedDate
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            ORDER BY CreatedDate DESC
        ];
        List<String> lines = new List<String>();
        Integer idx = 1;
        for (ContentVersion v : versions) {
            String size = (v.ContentSize != null) ? formatSize(v.ContentSize) : 'N/A';
            lines.add(idx + '. ' + v.Title + (v.FileExtension != null ? '.' + v.FileExtension : '') +
                ' | ' + (v.FileType != null ? v.FileType : 'Unknown') +
                ' | ' + size + ' | ' + v.CreatedDate.format('yyyy-MM-dd'));
            idx++;
        }
        out.found = true;
        out.fileCount = versions.size();
        out.filesSummary = String.join(lines, '\n');
        out.message = '📎 Attachments — ' + out.claimNumber + ' (' + versions.size() + ' file' + (versions.size() == 1 ? '' : 's') + ')\n' +
            '━━━━━━━━━━━━━━━━━━━━━━━\n' +
            out.filesSummary;
        return out;
    }

    private static String formatSize(Integer bytes) {
        if (bytes < 1024) { return bytes + 'B'; }
        if (bytes < 1024 * 1024) { return (bytes / 1024) + 'KB'; }
        return ((Decimal) bytes / 1048576).setScale(1) + 'MB';
    }
}