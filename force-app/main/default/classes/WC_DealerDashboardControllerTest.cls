@IsTest
private class WC_DealerDashboardControllerTest {

    @TestSetup
    static void setupTestData() {
        Account dealer = new Account(Name = 'Pune Electra Service Center');
        insert dealer;

        List<Claim> claims = new List<Claim>();

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Approved',
            Summary = 'EV Battery Module Assembly replacement under warranty',
            EstimatedAmount = 45000,
            Risk_Score__c = 15,
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-PUN-001',
            InitiationDate = Date.today(),
            AccountId = dealer.Id
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Approved',
            Summary = 'Regenerative Brake Controller calibration failure',
            EstimatedAmount = 12000,
            Risk_Score__c = 22,
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-PUN-001',
            InitiationDate = Date.today(),
            AccountId = dealer.Id
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Under Review',
            Summary = 'Onboard Charger Module intermittent fault',
            EstimatedAmount = 28000,
            Risk_Score__c = 55,
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-PUN-001',
            InitiationDate = Date.today(),
            AccountId = dealer.Id
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'Denied',
            Summary = 'Tire wear claim outside warranty coverage',
            EstimatedAmount = 3500,
            Risk_Score__c = 80,
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-PUN-001',
            InitiationDate = Date.today(),
            AccountId = dealer.Id
        ));

        claims.add(new Claim(
            Name = WC_ClaimNameGenerator.next(),
            Status = 'New',
            Summary = 'Drive Motor Inverter overheating during fast charge',
            EstimatedAmount = 38000,
            Risk_Score__c = 40,
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-PUN-001',
            InitiationDate = Date.today(),
            AccountId = dealer.Id
        ));

        insert claims;
    }

    @IsTest
    static void testGetMyClaimSummary() {
        Test.startTest();
        Map<String, Object> result = WC_DealerDashboardController.getMyClaimSummary();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Summary result should not be null');
        Integer totalClaims = (Integer) result.get('totalClaims');
        System.assertEquals(5, totalClaims, 'Should have 5 total claims');

        Map<String, Integer> statusCounts = (Map<String, Integer>) result.get('statusCounts');
        System.assert(!statusCounts.isEmpty(), 'Status counts should not be empty');
    }

    @IsTest
    static void testGetRecentClaims() {
        Test.startTest();
        List<Claim> claims = WC_DealerDashboardController.getRecentClaims();
        Test.stopTest();

        System.assertNotEquals(null, claims, 'Recent claims should not be null');
        System.assert(claims.size() <= 10, 'Should return at most 10 claims');
        System.assert(claims.size() > 0, 'Should return at least one claim');
    }

    @IsTest
    static void testGetWarrantyCoverage() {
        Test.startTest();
        Map<String, Object> result = WC_DealerDashboardController.getWarrantyCoverage();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Coverage result should not be null');
        System.assert(result.containsKey('activeCount'), 'Should contain activeCount key');
        System.assert(result.containsKey('expiredCount'), 'Should contain expiredCount key');
        System.assert(result.containsKey('totalCount'), 'Should contain totalCount key');
    }

    @IsTest
    static void testGetMyClaimSummaryInternalUser() {
        Test.startTest();
        Map<String, Object> result = WC_DealerDashboardController.getMyClaimSummary();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Internal user summary should not throw exception');
        System.assert(result.containsKey('totalClaims'), 'Should contain totalClaims key');
    }

    // Dealer-path tests: mock dealer account so WHERE AccountId = :id branches are covered
    @IsTest
    static void testGetMyClaimSummary_withDealerAccount() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WC_DealerDashboardController.mockDealerAccountId = dealer.Id;
        Test.startTest();
        Map<String, Object> result = WC_DealerDashboardController.getMyClaimSummary();
        Test.stopTest();
        System.assertNotEquals(null, result);
        System.assertEquals(5, (Integer) result.get('totalClaims'), 'Dealer should see their 5 test claims');
    }

    @IsTest
    static void testGetRecentClaims_withDealerAccount() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WC_DealerDashboardController.mockDealerAccountId = dealer.Id;
        Test.startTest();
        List<Claim> claims = WC_DealerDashboardController.getRecentClaims();
        Test.stopTest();
        System.assertNotEquals(null, claims);
        System.assert(claims.size() > 0, 'Dealer should see their claims');
        System.assert(claims.size() <= 10, 'Max 10 returned');
    }

    @IsTest
    static void testGetWarrantyCoverage_withDealerAccount_noAssets() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WC_DealerDashboardController.mockDealerAccountId = dealer.Id;
        Test.startTest();
        Map<String, Object> result = WC_DealerDashboardController.getWarrantyCoverage();
        Test.stopTest();
        System.assertNotEquals(null, result);
        System.assert(result.containsKey('activeCount'));
        System.assert(result.containsKey('expiredCount'));
        System.assert(result.containsKey('totalCount'));
        System.assertEquals(0, (Integer) result.get('activeCount'), 'No assets in test data');
    }
}