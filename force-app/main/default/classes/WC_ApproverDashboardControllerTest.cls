@IsTest
private class WC_ApproverDashboardControllerTest {

    @TestSetup
    static void setupData() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
        insert dealer;

        List<Claim> claims = new List<Claim>();

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Under Review',
            AccountId = dealer.Id,
            Summary = 'Battery thermal runaway warning during fast charge at Supercharger station',
            EstimatedAmount = 4500.00,
            InitiationDate = Date.today().addDays(-5),
            Risk_Score__c = 25,
            Channel__c = 'Portal',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Low risk - standard battery inspection recommended'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Under Review',
            AccountId = dealer.Id,
            Summary = 'Regenerative brake controller intermittent failure under heavy load',
            EstimatedAmount = 8200.00,
            InitiationDate = Date.today().addDays(-3),
            Risk_Score__c = 55,
            Channel__c = 'Phone',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Medium risk - brake system diagnostic required'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Under Review',
            AccountId = dealer.Id,
            Summary = 'Complete drivetrain failure at 12000 miles - vehicle immobilized',
            EstimatedAmount = 22000.00,
            InitiationDate = Date.today().addDays(-1),
            Risk_Score__c = 85,
            Channel__c = 'Email',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Critical risk - possible recall pattern, escalate immediately'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Approved',
            AccountId = dealer.Id,
            Summary = 'Minor paint defect on driver door panel',
            EstimatedAmount = 650.00,
            InitiationDate = Date.today().addDays(-14),
            Risk_Score__c = 10,
            Channel__c = 'Portal',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Low risk - cosmetic repair approved'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Approved',
            AccountId = dealer.Id,
            Summary = 'Infotainment system touchscreen unresponsive after OTA update',
            EstimatedAmount = 1800.00,
            InitiationDate = Date.today().addDays(-10),
            Risk_Score__c = 40,
            Channel__c = 'Phone',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Medium risk - software reflash and hardware check'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Denied',
            AccountId = dealer.Id,
            Summary = 'Aftermarket modification caused suspension damage',
            EstimatedAmount = 5500.00,
            InitiationDate = Date.today().addDays(-7),
            Risk_Score__c = 90,
            Channel__c = 'Email',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'High risk - warranty voided by unauthorized modification'
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'New',
            AccountId = dealer.Id,
            Summary = 'Windshield wiper motor failure during heavy rain',
            EstimatedAmount = 350.00,
            InitiationDate = Date.today(),
            Channel__c = 'Portal',
            DealerCode__c = 'BA-EM-001',
            AI_Recommendation__c = 'Pending risk assessment'
        ));

        insert claims;
    }

    @IsTest
    static void testGetPendingClaims() {
        List<WC_ApproverDashboardController.ClaimWrapper> pending =
            WC_ApproverDashboardController.getPendingClaims();

        System.assert(!pending.isEmpty(), 'Should return pending claims');

        Integer expectedPending = 0;
        for (Claim c : [SELECT Id FROM Claim WHERE Status IN ('New', 'Under Review', 'Submitted')]) {
            expectedPending++;
        }
        System.assertEquals(expectedPending, pending.size(), 'Should match pending claim count');

        for (Integer i = 1; i < pending.size(); i++) {
            Integer prev = pending[i - 1].riskScore;
            Integer curr = pending[i].riskScore;
            if (prev != null && curr != null) {
                System.assert(prev >= curr, 'Claims should be sorted by risk score DESC');
            }
        }

        for (WC_ApproverDashboardController.ClaimWrapper w : pending) {
            System.assertNotEquals(null, w.riskLevel, 'Risk level should be assigned');
            System.assertNotEquals(null, w.riskIcon, 'Risk icon should be assigned');
        }
    }

    @IsTest
    static void testGetStatusDistribution() {
        Map<String, Integer> dist = WC_ApproverDashboardController.getStatusDistribution();

        System.assert(!dist.isEmpty(), 'Status distribution should not be empty');
        Integer total = 0;
        for (Integer cnt : dist.values()) {
            total += cnt;
        }
        System.assertEquals(7, total, 'Should account for all 7 test claims');
    }

    @IsTest
    static void testGetRiskDistribution() {
        Map<String, Integer> buckets = WC_ApproverDashboardController.getRiskDistribution();

        System.assert(buckets.containsKey('Low'), 'Should have Low bucket');
        System.assert(buckets.containsKey('Medium'), 'Should have Medium bucket');
        System.assert(buckets.containsKey('High'), 'Should have High bucket');
        System.assert(buckets.containsKey('Critical'), 'Should have Critical bucket');

        Integer total = 0;
        for (Integer cnt : buckets.values()) {
            total += cnt;
        }
        Integer claimsWithRisk = [SELECT COUNT() FROM Claim WHERE Risk_Score__c != null];
        System.assertEquals(claimsWithRisk, total, 'Bucket totals should match claims with risk scores');
    }

    @IsTest
    static void testGetTodayActions() {
        Map<String, Integer> actions = WC_ApproverDashboardController.getTodayActions();

        System.assert(actions.containsKey('approvedToday'), 'Should have approvedToday key');
        System.assert(actions.containsKey('deniedToday'), 'Should have deniedToday key');
    }

    @IsTest
    static void testProcessClaimDecisionApprove() {
        Claim underReview = [SELECT Id, Name FROM Claim WHERE Status = 'Under Review' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = WC_ApproverDashboardController.processClaimDecision(
            underReview.Id, 'Approve', 'Approved after manual inspection'
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Approval should succeed');
        System.assertEquals('Approved', result.get('newStatus'), 'Status should be Approved');
        System.assertNotEquals(null, result.get('claimNumber'), 'Claim number should be returned');
    }

    @IsTest
    static void testProcessClaimDecisionInvalidAction() {
        Claim underReview = [SELECT Id FROM Claim WHERE Status = 'Under Review' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = WC_ApproverDashboardController.processClaimDecision(
            underReview.Id, 'InvalidAction', 'This should fail'
        );
        Test.stopTest();

        System.assertEquals(false, result.get('success'), 'Invalid action should fail');
        System.assert(
            ((String) result.get('message')).contains('Invalid action'),
            'Error message should mention invalid action'
        );
    }
}