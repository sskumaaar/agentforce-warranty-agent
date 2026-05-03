@IsTest
private class WC_ApproveRejectClaimTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'Bay Area Electra Motors');
        insert d;
        insert new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'Under Review',
            Summary = 'Approve wrapper test',
            EstimatedAmount = 45,
            InitiationDate = Date.today(),
            Risk_Score__c = 10,
            Channel__c = 'Web_Chat',
            DealerCode__c = 'DLR-001'
        );
    }

    @IsTest
    static void testApprove() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Approve';
        req.comments = 'Parts verified for Electra Cars warranty.';
        req.approvedAmount = 45;
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess, r[0].errorMessage);
        System.assertEquals('Approved', r[0].newStatus);
        Claim verify = [SELECT Status, ApprovedBy__c, ApprovalDate__c, Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Approved', verify.Status);
        System.assertNotEquals(null, verify.ApprovedBy__c);
        System.assertNotEquals(null, verify.ApprovalDate__c);
    }

    @IsTest
    static void testReject() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Reject';
        req.comments = 'Warranty expired';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess, r[0].errorMessage);
        System.assertEquals('Denied', r[0].newStatus);
        Claim verify = [SELECT Status, RejectedBy__c, RejectionReason__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Denied', verify.Status);
        System.assertNotEquals(null, verify.RejectedBy__c);
        System.assert(verify.RejectionReason__c.contains('Warranty'));
    }

    @IsTest
    static void testMissingRequiredFields() {
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        // all fields blank
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('required'));
    }

    @IsTest
    static void testInvalidDecision() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Maybe';
        req.comments = 'Unclear';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('Approve or Reject'));
    }

    @IsTest
    static void testClaimNotFound() {
        Claim tmp = [SELECT Id FROM Claim LIMIT 1];
        Id deletedId = tmp.Id;
        delete tmp;
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = deletedId;
        req.decision = 'Approve';
        req.comments = 'Test';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('not found'));
    }

    @IsTest
    static void testDoubleApprove() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        c.Status = 'Approved';
        update c;
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Approve';
        req.comments = 'Duplicate attempt';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('already approved'));
    }

    @IsTest
    static void testDoubleReject() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        c.Status = 'Denied';
        update c;
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Reject';
        req.comments = 'Duplicate';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assert(r[0].errorMessage.contains('already denied'));
    }

    @IsTest
    static void testNullRequests() {
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r = WC_ApproveRejectClaim.decide(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    @IsTest
    static void testInvalidClaimIdFormat() {
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = 'not-a-valid-id';
        req.decision = 'Approve';
        req.comments = 'Test invalid format';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(!r[0].isSuccess);
        System.assertNotEquals(null, r[0].errorMessage);
    }

    @IsTest
    static void testRejectWithApprovedAmount_ignored() {
        // Reject path should ignore approvedAmount
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Reject';
        req.comments = 'Denied';
        req.approvedAmount = 999;  // should be ignored on reject
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess);
        System.assertEquals('Denied', r[0].newStatus);
    }

    @IsTest
    static void testApproveByClaimNumber() {
        Claim c = [SELECT Id, Name FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimNumber = c.Name;
        req.decision = 'Approve';
        req.comments = 'Approved by claim number';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess, r[0].errorMessage);
        System.assertEquals('Approved', r[0].newStatus);
    }

    @IsTest
    static void testTolerantDecisionValues() {
        // Apex must accept Approved, Approve, Rejected, Reject, Deny, Denied
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        for (String v : new List<String>{ 'Approved', 'approve', 'APPROVE' }) {
            // reset claim
            update new Claim(Id = c.Id, Status = 'Under Review');
            WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
            req.claimId = c.Id;
            req.decision = v;
            req.comments = 'Tolerance test ' + v;
            List<WC_ApproveRejectClaim.DecisionResponse> r =
                WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
            System.assert(r[0].isSuccess, 'Decision value ' + v + ' should be accepted; got: ' + r[0].errorMessage);
            System.assertEquals('Approved', r[0].newStatus);
        }
        for (String v : new List<String>{ 'Rejected', 'Deny', 'denied' }) {
            update new Claim(Id = c.Id, Status = 'Under Review');
            WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
            req.claimId = c.Id;
            req.decision = v;
            req.comments = 'Tolerance test ' + v;
            List<WC_ApproveRejectClaim.DecisionResponse> r =
                WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
            System.assert(r[0].isSuccess, 'Decision value ' + v + ' should be accepted; got: ' + r[0].errorMessage);
            System.assertEquals('Denied', r[0].newStatus);
        }
    }

    @IsTest
    static void testApprovePublishesEvent() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ApproveRejectClaim.DecisionRequest req = new WC_ApproveRejectClaim.DecisionRequest();
        req.claimId = c.Id;
        req.decision = 'Approve';
        req.comments = 'Event publish test';
        req.channel = 'Slack';
        Test.startTest();
        List<WC_ApproveRejectClaim.DecisionResponse> r =
            WC_ApproveRejectClaim.decide(new List<WC_ApproveRejectClaim.DecisionRequest>{ req });
        Test.stopTest();
        System.assert(r[0].isSuccess);
        System.assertEquals(true, r[0].notificationSent, 'EventBus.publish should have succeeded');
    }
}