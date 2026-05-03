public with sharing class WC_SharedFileService {

    @AuraEnabled(cacheable=true)
    public static List<WC_Shared_File__c> getSharedFiles() {
        return [
            SELECT Id, Name, File_Name__c, File_Path__c, Category__c,
                   Current_Version__c, Latest_Summary__c, Last_Updated_By__c,
                   LastModifiedDate
            FROM WC_Shared_File__c
            ORDER BY Category__c ASC, File_Name__c ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<WC_File_Version__c> getFileVersions(Id sharedFileId) {
        return [
            SELECT Id, Name, Version_Number__c, Change_Summary__c,
                   Uploaded_By__c, Upload_Date__c
            FROM WC_File_Version__c
            WHERE Shared_File__c = :sharedFileId
            ORDER BY Version_Number__c DESC
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static Map<String, Object> uploadNewVersion(
        String fileName, String filePath, String category,
        String newContent, String uploadedBy
    ) {
        List<WC_Shared_File__c> existing = [
            SELECT Id, File_Content__c, Current_Version__c
            FROM WC_Shared_File__c
            WHERE File_Name__c = :fileName
            LIMIT 1
        ];

        String changeSummary;
        Decimal nextVersion;
        WC_Shared_File__c file;

        if (existing.isEmpty()) {
            changeSummary = extractPurpose(newContent);
            nextVersion = 1;
            file = new WC_Shared_File__c(
                File_Name__c = fileName,
                File_Path__c = filePath,
                Category__c = category,
                Current_Version__c = nextVersion,
                Latest_Summary__c = changeSummary,
                Last_Updated_By__c = uploadedBy,
                File_Content__c = newContent
            );
            insert file;
        } else {
            file = existing[0];
            String oldContent = file.File_Content__c != null ? file.File_Content__c : '';
            changeSummary = generateDiffSummary(oldContent, newContent);
            nextVersion = (file.Current_Version__c != null ? file.Current_Version__c : 0) + 1;

            file.Current_Version__c = nextVersion;
            file.Latest_Summary__c = changeSummary;
            file.Last_Updated_By__c = uploadedBy;
            file.File_Content__c = newContent;
            update file;
        }

        WC_File_Version__c ver = new WC_File_Version__c(
            Shared_File__c = file.Id,
            Version_Number__c = nextVersion,
            Change_Summary__c = changeSummary,
            Uploaded_By__c = uploadedBy,
            File_Content__c = newContent,
            Upload_Date__c = Datetime.now()
        );
        insert ver;

        Map<String, Object> result = new Map<String, Object>();
        result.put('fileId', file.Id);
        result.put('versionId', ver.Id);
        result.put('versionNumber', nextVersion);
        result.put('changeSummary', changeSummary);
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> previewUpload(String fileName, String newContent) {
        List<WC_Shared_File__c> existing = [
            SELECT Id, File_Content__c, Current_Version__c, Last_Updated_By__c
            FROM WC_Shared_File__c
            WHERE File_Name__c = :fileName
            LIMIT 1
        ];

        Map<String, Object> preview = new Map<String, Object>();
        if (existing.isEmpty()) {
            preview.put('isNew', true);
            preview.put('changeSummary', extractPurpose(newContent));
            preview.put('nextVersion', 1);
        } else {
            WC_Shared_File__c file = existing[0];
            String oldContent = file.File_Content__c != null ? file.File_Content__c : '';
            String summary = generateDiffSummary(oldContent, newContent);
            Boolean hasChanges = oldContent != newContent;

            preview.put('isNew', false);
            preview.put('hasChanges', hasChanges);
            preview.put('changeSummary', summary);
            preview.put('currentVersion', file.Current_Version__c);
            preview.put('nextVersion', (file.Current_Version__c != null ? file.Current_Version__c : 0) + 1);
            preview.put('lastUpdatedBy', file.Last_Updated_By__c);
        }
        return preview;
    }

    @AuraEnabled
    public static String getFileContent(Id sharedFileId) {
        WC_Shared_File__c f = [
            SELECT File_Content__c FROM WC_Shared_File__c
            WHERE Id = :sharedFileId LIMIT 1
        ];
        return f.File_Content__c;
    }

    @AuraEnabled
    public static String getVersionContent(Id versionId) {
        WC_File_Version__c v = [
            SELECT File_Content__c FROM WC_File_Version__c
            WHERE Id = :versionId LIMIT 1
        ];
        return v.File_Content__c;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> checkForUpdates(String fileVersionsJson) {
        Map<String, Decimal> localVersions = new Map<String, Decimal>();
        if (String.isNotBlank(fileVersionsJson)) {
            List<Object> entries = (List<Object>) JSON.deserializeUntyped(fileVersionsJson);
            for (Object entry : entries) {
                Map<String, Object> e = (Map<String, Object>) entry;
                String fName = (String) e.get('fileName');
                Decimal ver = (Decimal) e.get('version');
                localVersions.put(fName, ver);
            }
        }

        List<Map<String, Object>> updates = new List<Map<String, Object>>();
        for (WC_Shared_File__c sf : [
            SELECT File_Name__c, File_Path__c, Current_Version__c,
                   Latest_Summary__c, Last_Updated_By__c, LastModifiedDate
            FROM WC_Shared_File__c
            ORDER BY File_Name__c
        ]) {
            Decimal localVer = localVersions.containsKey(sf.File_Name__c)
                ? localVersions.get(sf.File_Name__c) : 0;
            if (sf.Current_Version__c > localVer) {
                Map<String, Object> u = new Map<String, Object>();
                u.put('fileName', sf.File_Name__c);
                u.put('filePath', sf.File_Path__c);
                u.put('localVersion', localVer);
                u.put('remoteVersion', sf.Current_Version__c);
                u.put('changeSummary', sf.Latest_Summary__c);
                u.put('updatedBy', sf.Last_Updated_By__c);
                u.put('updatedDate', sf.LastModifiedDate);
                updates.add(u);
            }
        }
        return updates;
    }

    public static String generateDiffSummary(String oldText, String newText) {
        if (String.isBlank(oldText) && String.isBlank(newText)) {
            return 'No content';
        }
        if (String.isBlank(oldText)) {
            Integer lineCount = newText.split('\n').size();
            return 'New content added (' + lineCount + ' lines)';
        }
        if (oldText == newText) {
            return 'No changes detected';
        }

        List<String> oldLines = oldText.split('\n');
        List<String> newLines = newText.split('\n');

        List<String> modifiedHeadings = new List<String>();
        findModifiedSections(oldLines, newLines, modifiedHeadings);

        Set<String> oldSet = new Set<String>();
        Set<String> newSet = new Set<String>();
        for (String l : oldLines) oldSet.add(l.trim());
        for (String l : newLines) newSet.add(l.trim());

        Integer addedCount = 0;
        Integer removedCount = 0;
        for (String l : newLines) {
            if (!oldSet.contains(l.trim()) && String.isNotBlank(l.trim())) addedCount++;
        }
        for (String l : oldLines) {
            if (!newSet.contains(l.trim()) && String.isNotBlank(l.trim())) removedCount++;
        }

        List<String> parts = new List<String>();

        if (!modifiedHeadings.isEmpty()) {
            parts.add('Changed: ' + String.join(modifiedHeadings, ', '));
        }

        if (addedCount > 0 && removedCount > 0) {
            parts.add('+' + addedCount + '/-' + removedCount + ' lines');
        } else if (addedCount > 0) {
            parts.add('+' + addedCount + ' lines');
        } else if (removedCount > 0) {
            parts.add('-' + removedCount + ' lines');
        }

        return parts.isEmpty() ? 'Minor formatting changes' : String.join(parts, ' | ');
    }

    private static void findModifiedSections(
        List<String> oldLines, List<String> newLines, List<String> headings
    ) {
        Map<String, List<String>> oldSections = extractSections(oldLines);
        Map<String, List<String>> newSections = extractSections(newLines);

        for (String heading : newSections.keySet()) {
            if (headings.size() >= 5) break;
            if (!oldSections.containsKey(heading)) {
                headings.add(heading + ' [new]');
            } else {
                String oldBody = String.join(oldSections.get(heading), '\n');
                String newBody = String.join(newSections.get(heading), '\n');
                if (oldBody != newBody) {
                    headings.add(heading + ' [modified]');
                }
            }
        }
        for (String heading : oldSections.keySet()) {
            if (headings.size() >= 5) break;
            if (!newSections.containsKey(heading)) {
                headings.add(heading + ' [removed]');
            }
        }
    }

    private static Map<String, List<String>> extractSections(List<String> lines) {
        Map<String, List<String>> sections = new Map<String, List<String>>();
        String currentHeading = '(top)';
        List<String> currentBody = new List<String>();

        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.startsWith('#')) {
                if (!currentBody.isEmpty()) {
                    sections.put(currentHeading, currentBody);
                }
                currentHeading = trimmed.replaceAll('^#+\\s*', '');
                currentBody = new List<String>();
            } else {
                currentBody.add(line);
            }
        }
        if (!currentBody.isEmpty()) {
            sections.put(currentHeading, currentBody);
        }
        return sections;
    }

    @TestVisible
    private static String extractPurpose(String content) {
        if (String.isBlank(content)) return 'New file (empty)';
        List<String> lines = content.split('\n');

        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.startsWith('description:')) {
                String descText = trimmed.substring(12).trim();
                if (descText.length() > 0) {
                    return descText.length() > 200 ? descText.substring(0, 200) + '...' : descText;
                }
            }
        }

        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.startsWith('#') && trimmed.length() > 2) {
                String heading = trimmed.replaceAll('^#+\\s*', '');
                if (heading.length() > 0) return heading;
            }
        }

        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.length() > 0 && !trimmed.startsWith('---') && !trimmed.startsWith('```')) {
                return trimmed.length() > 200 ? trimmed.substring(0, 200) + '...' : trimmed;
            }
        }

        return 'New file added';
    }
}