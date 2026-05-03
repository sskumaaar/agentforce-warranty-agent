@IsTest
private class WC_GetClaimAttachmentsTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'Attachments Test Dealer');
        insert d;
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'Under Review',
            Summary = 'Attachments test',
            EstimatedAmount = 200,
            InitiationDate = Date.today(),
            Channel__c = 'Web_Chat',
            DealerCode__c = 'DLR-ATT'
        );
        insert c;

        ContentVersion cv = new ContentVersion(
            Title = 'Diagnostic Scan',
            PathOnClient = 'scan.pdf',
            VersionData = Blob.valueOf('SCAN-FIXTURE-DATA'),
            IsMajorVersion = true
        );
        insert cv;
        ContentVersion stored = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        insert new ContentDocumentLink(
            LinkedEntityId = c.Id,
            ContentDocumentId = stored.ContentDocumentId,
            ShareType = 'V'
        );
    }

    @IsTest
    static void testByClaimId() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_GetClaimAttachments.Input inp = new WC_GetClaimAttachments.Input();
        inp.claimId = c.Id;
        Test.startTest();
        List<WC_GetClaimAttachments.Output> r =
            WC_GetClaimAttachments.getAttachments(new List<WC_GetClaimAttachments.Input>{ inp });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assert(r[0].found);
        System.assertEquals(1, r[0].fileCount);
        System.assert(r[0].filesSummary.contains('Diagnostic Scan'));
    }

    @IsTest
    static void testByClaimNumber() {
        Claim c = [SELECT Name FROM Claim LIMIT 1];
        WC_GetClaimAttachments.Input inp = new WC_GetClaimAttachments.Input();
        inp.claimNumber = c.Name;
        Test.startTest();
        List<WC_GetClaimAttachments.Output> r =
            WC_GetClaimAttachments.getAttachments(new List<WC_GetClaimAttachments.Input>{ inp });
        Test.stopTest();
        System.assert(r[0].found, 'claimNumber path should resolve');
        System.assertEquals(c.Name, r[0].claimNumber);
    }

    @IsTest
    static void testNoAttachments() {
        Account d = [SELECT Id FROM Account LIMIT 1];
        Claim empty = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'New',
            Summary = 'No attachments',
            EstimatedAmount = 50,
            InitiationDate = Date.today()
        );
        insert empty;

        WC_GetClaimAttachments.Input inp = new WC_GetClaimAttachments.Input();
        inp.claimId = empty.Id;
        Test.startTest();
        List<WC_GetClaimAttachments.Output> r =
            WC_GetClaimAttachments.getAttachments(new List<WC_GetClaimAttachments.Input>{ inp });
        Test.stopTest();
        System.assertEquals(false, r[0].found);
        System.assertEquals(0, r[0].fileCount);
        System.assert(r[0].message.contains('No attachments'));
    }

    @IsTest
    static void testMissingInputs() {
        WC_GetClaimAttachments.Input inp = new WC_GetClaimAttachments.Input();
        Test.startTest();
        List<WC_GetClaimAttachments.Output> r =
            WC_GetClaimAttachments.getAttachments(new List<WC_GetClaimAttachments.Input>{ inp });
        Test.stopTest();
        System.assertEquals(false, r[0].found);
        System.assert(r[0].message.contains('required'));
    }

    @IsTest
    static void testNullInputs() {
        Test.startTest();
        List<WC_GetClaimAttachments.Output> r = WC_GetClaimAttachments.getAttachments(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }
}