@IsTest
private class WC_SendDealerFollowUpTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'Pune Electra Service Center');
        insert d;
        insert new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'Under Review',
            Summary = 'Follow-up test',
            EstimatedAmount = 200,
            InitiationDate = Date.today(),
            Channel__c = 'Web_Chat',
            DealerCode__c = 'DLR-002'
        );
    }

    @IsTest
    static void testSendFollowUp_Email() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = c.Id;
        req.questions = 'Please provide odometer at time of failure.';
        req.channel = 'Email';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assert(r[0].isSuccess, r[0].errorMessage);
        System.assert(r[0].confirmationMessage.contains('WC-'), 'Confirmation should reference WC-prefixed claim name');
        Claim updated = [SELECT Status, Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Requested Information', updated.Status, 'Status should be Requested Information');
        System.assert(updated.Approver_Comments__c.contains('[Email '),
            'Comment should be tagged with channel + timestamp; got: ' + updated.Approver_Comments__c);
        System.assert(updated.Approver_Comments__c.contains('odometer'));
    }

    @IsTest
    static void testSendFollowUp_defaultChannel() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = c.Id;
        req.questions = 'Test question';
        // channel omitted — defaults to 'Email'
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess);
        Claim updated = [SELECT Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assert(updated.Approver_Comments__c.contains('[Email '), 'Default channel should be Email');
    }

    @IsTest
    static void testSendFollowUp_customChannel() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = c.Id;
        req.questions = 'WhatsApp test';
        req.channel = 'WhatsApp';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        Claim updated = [SELECT Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assert(updated.Approver_Comments__c.contains('[WhatsApp '));
    }

    @IsTest
    static void testMissingClaimId() {
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.questions = 'Question without claim';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('required'));
    }

    @IsTest
    static void testMissingQuestions() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = c.Id;
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('required'));
    }

    @IsTest
    static void testClaimNotFound() {
        Claim tmp = [SELECT Id FROM Claim LIMIT 1];
        Id deletedId = tmp.Id;
        delete tmp;
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = deletedId;
        req.questions = 'Question to nonexistent claim';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('not found'));
    }

    @IsTest
    static void testNullRequests() {
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r = WC_SendDealerFollowUp.sendFollowUp(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    @IsTest
    static void testInvalidClaimIdFormat() {
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = 'not-a-valid-id';
        req.questions = 'Test';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assertNotEquals(null, r[0].errorMessage);
    }

    @IsTest
    static void testEventPublishedOnSuccess() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
        req.claimId = c.Id;
        req.questions = 'Need diagnostic scan output and repair invoice.';
        req.channel = 'Slack';
        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r =
            WC_SendDealerFollowUp.sendFollowUp(new List<WC_SendDealerFollowUp.FollowUpRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess, r[0].errorMessage);
        System.assertEquals(true, r[0].notificationSent, 'EventBus.publish should have succeeded for InfoRequested event');
        System.assert(r[0].confirmationMessage.contains('successfully'), 'Confirmation should report event success');
    }

    @IsTest
    static void testBulk() {
        Account d = [SELECT Id FROM Account LIMIT 1];
        List<Claim> bulkClaims = new List<Claim>();
        for (Integer i = 0; i < 5; i++) {
            bulkClaims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id,
                Status = 'Under Review',
                Summary = 'Bulk ' + i,
                EstimatedAmount = 100 + i,
                InitiationDate = Date.today()
            ));
        }
        insert bulkClaims;

        List<WC_SendDealerFollowUp.FollowUpRequest> reqs = new List<WC_SendDealerFollowUp.FollowUpRequest>();
        for (Claim c : bulkClaims) {
            WC_SendDealerFollowUp.FollowUpRequest req = new WC_SendDealerFollowUp.FollowUpRequest();
            req.claimId = c.Id;
            req.questions = 'Bulk question';
            req.channel = 'Portal';
            reqs.add(req);
        }

        Test.startTest();
        List<WC_SendDealerFollowUp.FollowUpResponse> r = WC_SendDealerFollowUp.sendFollowUp(reqs);
        Test.stopTest();
        System.assertEquals(5, r.size());
        for (WC_SendDealerFollowUp.FollowUpResponse resp : r) {
            System.assert(resp.isSuccess, resp.errorMessage);
        }
    }
}