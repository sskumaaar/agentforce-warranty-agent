@IsTest
private class WC_SharedFileServiceTest {

    @IsTest
    static void testUploadNewFile() {
        String content = '# Test Rule\n\nSome instructions here.\n## Section A\nDo this.';
        Map<String, Object> result = WC_SharedFileService.uploadNewVersion(
            'test-rule.mdc', '.cursor/rules/test-rule.mdc',
            'Cursor Rule', content, 'Santosh'
        );

        System.assertNotEquals(null, result.get('fileId'), 'Should return file Id');
        System.assertEquals(1, (Decimal) result.get('versionNumber'), 'First upload = v1');
        String summary = (String) result.get('changeSummary');
        System.assert(
            summary != null && summary.length() > 0,
            'First version summary should describe the file purpose'
        );

        WC_Shared_File__c file = [
            SELECT File_Name__c, Current_Version__c, File_Content__c
            FROM WC_Shared_File__c WHERE Id = :(Id) result.get('fileId')
        ];
        System.assertEquals('test-rule.mdc', file.File_Name__c);
        System.assertEquals(1, file.Current_Version__c);
        System.assertEquals(content, file.File_Content__c);
    }

    @IsTest
    static void testUploadSecondVersion() {
        String v1 = '# Rule\n## Section A\nLine 1\nLine 2';
        WC_SharedFileService.uploadNewVersion(
            'test-rule.mdc', '.cursor/rules/test-rule.mdc',
            'Cursor Rule', v1, 'Santosh'
        );

        String v2 = '# Rule\n## Section A\nLine 1\nLine 2\nLine 3 added\n## Section B\nNew section';
        Map<String, Object> result = WC_SharedFileService.uploadNewVersion(
            'test-rule.mdc', '.cursor/rules/test-rule.mdc',
            'Cursor Rule', v2, 'Piyush'
        );

        System.assertEquals(2, (Decimal) result.get('versionNumber'), 'Second upload = v2');
        String summary = (String) result.get('changeSummary');
        System.assert(summary.contains('+') && summary.contains('lines'), 'Summary should mention added lines with +N lines format');

        List<WC_File_Version__c> versions = [
            SELECT Version_Number__c FROM WC_File_Version__c
            WHERE Shared_File__c = :(Id) result.get('fileId')
            ORDER BY Version_Number__c
        ];
        System.assertEquals(2, versions.size(), 'Should have 2 version records');
    }

    @IsTest
    static void testPreviewUploadNewFile() {
        Map<String, Object> preview = WC_SharedFileService.previewUpload(
            'new-file.mdc', '# New File\nContent here'
        );
        System.assertEquals(true, preview.get('isNew'));
        System.assertEquals(1, (Decimal) preview.get('nextVersion'));
    }

    @IsTest
    static void testPreviewUploadExistingFile() {
        WC_SharedFileService.uploadNewVersion(
            'existing.mdc', '.cursor/rules/existing.mdc',
            'Cursor Rule', '# Original\nLine 1', 'Santosh'
        );

        Map<String, Object> preview = WC_SharedFileService.previewUpload(
            'existing.mdc', '# Original\nLine 1\nLine 2 new'
        );
        System.assertEquals(false, preview.get('isNew'));
        System.assertEquals(true, preview.get('hasChanges'));
        System.assertEquals(2, (Decimal) preview.get('nextVersion'));
    }

    @IsTest
    static void testPreviewNoChanges() {
        String content = '# Same Content\nNo changes';
        WC_SharedFileService.uploadNewVersion(
            'same.mdc', '.cursor/rules/same.mdc', 'Cursor Rule', content, 'Santosh'
        );

        Map<String, Object> preview = WC_SharedFileService.previewUpload('same.mdc', content);
        System.assertEquals(false, preview.get('hasChanges'));
    }

    @IsTest
    static void testGetSharedFiles() {
        WC_SharedFileService.uploadNewVersion(
            'a.mdc', '.cursor/rules/a.mdc', 'Cursor Rule', 'content a', 'Santosh'
        );
        WC_SharedFileService.uploadNewVersion(
            'b.md', 'CLAUDE.md', 'Config', 'content b', 'Piyush'
        );

        List<WC_Shared_File__c> files = WC_SharedFileService.getSharedFiles();
        System.assertEquals(2, files.size());
    }

    @IsTest
    static void testGetFileVersions() {
        Map<String, Object> r1 = WC_SharedFileService.uploadNewVersion(
            'versioned.mdc', '.cursor/rules/versioned.mdc',
            'Cursor Rule', 'v1 content', 'Santosh'
        );
        WC_SharedFileService.uploadNewVersion(
            'versioned.mdc', '.cursor/rules/versioned.mdc',
            'Cursor Rule', 'v2 content', 'Piyush'
        );

        List<WC_File_Version__c> versions = WC_SharedFileService.getFileVersions(
            (Id) r1.get('fileId')
        );
        System.assertEquals(2, versions.size());
        System.assertEquals(2, versions[0].Version_Number__c, 'Newest first');
    }

    @IsTest
    static void testGetFileContent() {
        Map<String, Object> r = WC_SharedFileService.uploadNewVersion(
            'content.mdc', '.cursor/rules/content.mdc',
            'Cursor Rule', 'full content here', 'Santosh'
        );
        String content = WC_SharedFileService.getFileContent((Id) r.get('fileId'));
        System.assertEquals('full content here', content);
    }

    @IsTest
    static void testGetVersionContent() {
        Map<String, Object> r = WC_SharedFileService.uploadNewVersion(
            'vc.mdc', '.cursor/rules/vc.mdc', 'Cursor Rule', 'snapshot', 'Santosh'
        );
        String content = WC_SharedFileService.getVersionContent((Id) r.get('versionId'));
        System.assertEquals('snapshot', content);
    }

    @IsTest
    static void testCheckForUpdates() {
        WC_SharedFileService.uploadNewVersion(
            'rule-a.mdc', '.cursor/rules/rule-a.mdc', 'Cursor Rule', 'v1', 'Santosh'
        );
        WC_SharedFileService.uploadNewVersion(
            'rule-b.mdc', '.cursor/rules/rule-b.mdc', 'Cursor Rule', 'v1', 'Santosh'
        );

        String json = '[{"fileName":"rule-a.mdc","version":1},{"fileName":"rule-b.mdc","version":0}]';
        List<Map<String, Object>> updates = WC_SharedFileService.checkForUpdates(json);
        System.assertEquals(1, updates.size(), 'Only rule-b should show as update');
        System.assertEquals('rule-b.mdc', updates[0].get('fileName'));
    }

    @IsTest
    static void testGenerateDiffSummary() {
        String oldText = '# Rule\n## Section A\nLine 1\nLine 2';
        String newText = '# Rule\n## Section A\nLine 1\nLine 2\nLine 3\n## Section B\nNew stuff';

        String summary = WC_SharedFileService.generateDiffSummary(oldText, newText);
        System.assert(summary.contains('+'), 'Should mention additions with + prefix');
        System.assert(summary.contains('lines'), 'Should show line count change');
    }

    @IsTest
    static void testGenerateDiffSummaryNoChange() {
        String same = '# Rule\nContent';
        String summary = WC_SharedFileService.generateDiffSummary(same, same);
        System.assertEquals('No changes detected', summary);
    }

    @IsTest
    static void testGenerateDiffSummaryFromBlank() {
        String summary = WC_SharedFileService.generateDiffSummary('', '# New\nContent');
        System.assert(summary.contains('added'), 'Diff from blank should mention lines added');
    }
}