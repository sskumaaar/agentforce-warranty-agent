@IsTest
private class WC_ClaimDecisionTest {

    @TestSetup
    static void setupTestData() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
        insert dealer;

        Claim testClaim = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'Under Review',
            Summary = 'Brake controller failure - pending approval',
            EstimatedAmount = 45000,
            InitiationDate = Date.today(),
            Risk_Score__c = 35,
            AI_Recommendation__c = 'Review',
            Channel__c = 'Web_Chat',
            DealerCode__c = 'DLR-001'
        );
        insert testClaim;
    }

    @IsTest
    static void testApproveClaim() {
        Claim c = [SELECT Id, Name FROM Claim LIMIT 1];

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Approve';
        inp.comments = 'Verified with dealer - genuine OEM part, catalog code entry error.';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        WC_ClaimDecision.Output out = results[0];
        System.assert(out.success, 'Should succeed: ' + out.message);
        System.assertEquals('Approved', out.newStatus);
        System.assert(out.message.contains('APPROVED'));

        Claim updated = [SELECT Status, ApprovedBy__c, ApprovalDate__c, Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Approved', updated.Status);
        System.assertEquals(UserInfo.getUserId(), updated.ApprovedBy__c);
        System.assertNotEquals(null, updated.ApprovalDate__c);
        System.assert(updated.Approver_Comments__c.contains('genuine OEM'));
    }

    @IsTest
    static void testRejectClaimWithReason() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Reject';
        inp.rejectionReason = 'Warranty expired. Mileage exceeds coverage limit.';
        inp.comments = 'Dealer notified of denial.';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(results[0].success, 'Should succeed');
        System.assertEquals('Denied', results[0].newStatus);

        Claim updated = [SELECT Status, RejectedBy__c, RejectionReason__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Denied', updated.Status);
        System.assertEquals(UserInfo.getUserId(), updated.RejectedBy__c);
        System.assert(updated.RejectionReason__c.contains('Warranty expired'));
    }

    @IsTest
    static void testRejectWithoutReason() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Reject';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(!results[0].success, 'Should fail without reason');
        System.assert(results[0].message.contains('mandatory'), 'Should mention mandatory reason');
    }

    @IsTest
    static void testRequestInfo() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'RequestInfo';
        inp.comments = 'Please provide photos of damaged brake controller and diagnostic report.';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(results[0].success, 'Should succeed');
        System.assertEquals('Requested Information', results[0].newStatus);
    }

    @IsTest
    static void testInvalidAction() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Delete';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(!results[0].success, 'Should fail for invalid action');
        System.assert(results[0].message.contains('Invalid action'));
    }

    @IsTest
    static void testClaimNotFound() {
        Claim temp = [SELECT Id FROM Claim LIMIT 1];
        Id claimId = temp.Id;
        delete temp;

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = claimId;
        inp.action = 'Approve';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(!results[0].success);
        System.assert(results[0].message.contains('not found'));
    }

    @IsTest
    static void testMissingRequiredFields() {
        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(!results[0].success);
        System.assert(results[0].message.contains('required'));
    }

    @IsTest
    static void testEscalateClaim() {
        Claim c = [SELECT Id, Status FROM Claim LIMIT 1];
        String origStatus = c.Status;

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Escalate';
        inp.comments = 'Escalating to senior approver for high-value Electra battery claim.';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(results[0].success, 'Escalate should succeed');
        System.assertEquals(origStatus, results[0].newStatus, 'Status should not change on escalation');

        Claim updated = [SELECT Approver_Comments__c FROM Claim WHERE Id = :c.Id];
        System.assert(updated.Approver_Comments__c.contains('ESCALATED'), 'Comments should contain ESCALATED prefix');
    }

    @IsTest
    static void testAddNote() {
        Claim c = [SELECT Id, Status FROM Claim LIMIT 1];
        String origStatus = c.Status;

        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'AddNote';
        inp.comments = 'Internal note: dealer has submitted revised documentation.';

        Test.startTest();
        List<WC_ClaimDecision.Output> results =
            WC_ClaimDecision.processDecision(new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(results[0].success, 'AddNote should succeed');
        System.assertEquals(origStatus, results[0].newStatus, 'Status should not change on note');
        System.assert(results[0].message.contains('Internal note added'));
    }

    // [v22.3] 3 C's audit trail tests — Cause + Correction persistence and
    // engine-level fallback when caller didn't supply a Cause.

    @IsTest
    static void testApprovePersistsRootCauseAndCorrection() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action  = 'Approve';
        inp.comments = 'Approved on first review.';
        inp.rootCause = 'Cell imbalance after thermal event during fast charging.';
        inp.correction = 'Replace battery pack assembly P-BAT-EV-2024-001 + recalibrate BMS.';

        Test.startTest();
        List<WC_ClaimDecision.Output> r = WC_ClaimDecision.processDecision(
            new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(r[0].success, 'Approve must succeed: ' + r[0].message);
        Claim updated = [SELECT Status, RootCause__c, CorrectionDescription__c
                         FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Approved', updated.Status);
        System.assertEquals('Cell imbalance after thermal event during fast charging.',
            updated.RootCause__c, 'RootCause__c must persist exactly');
        System.assert(updated.CorrectionDescription__c.contains('battery pack assembly'),
            'CorrectionDescription__c must persist exactly');
    }

    @IsTest
    static void testApproveEngineStampsAutoFallbackWhenCauseBlank() {
        // Engine stays permissive — flow-driven auto-approves don't carry Cause.
        // Engine must stamp 'Auto-decided by Atlas Triage' so the audit field
        // is never blank on an approved claim.
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action  = 'Approve';
        inp.comments = 'Auto-approved (low risk).';
        // rootCause intentionally blank.

        Test.startTest();
        List<WC_ClaimDecision.Output> r = WC_ClaimDecision.processDecision(
            new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(r[0].success, 'Engine must approve without Cause (controller validates)');
        Claim updated = [SELECT RootCause__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals('Auto-decided by Atlas Triage', updated.RootCause__c,
            'Engine must stamp the auto-fallback when Cause is blank');
    }

    @IsTest
    static void testRejectAllowsBlankRootCause() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = c.Id;
        inp.action = 'Reject';
        inp.rejectionReason = 'Warranty expired.';
        // rootCause blank — Reject path doesn't require it.

        Test.startTest();
        List<WC_ClaimDecision.Output> r = WC_ClaimDecision.processDecision(
            new List<WC_ClaimDecision.Input>{ inp });
        Test.stopTest();

        System.assert(r[0].success, 'Reject without Cause must succeed: ' + r[0].message);
        System.assertEquals('Denied', r[0].newStatus);
    }
}