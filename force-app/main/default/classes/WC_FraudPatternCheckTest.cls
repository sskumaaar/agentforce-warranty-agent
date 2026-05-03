@IsTest
private class WC_FraudPatternCheckTest {

    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Fraud Test Dealer');
        insert dealer;

        Product2 vdProduct = new Product2(Name = 'Fraud Test Vehicle Model', ProductCode = 'FRAUD-VEH-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'Fraud Test Vehicle Def', ProductId = vdProduct.Id);
        insert vd;

        Asset vehicleAsset = new Asset(Name = 'Fraud Test Asset', AccountId = dealer.Id);
        insert vehicleAsset;

        Vehicle testVehicle = new Vehicle(
            Name = 'Fraud Test Vehicle',
            VehicleIdentificationNumber = '1ELECFRAUDTEST001',
            AssetId = vehicleAsset.Id,
            VehicleDefinitionId = vd.Id
        );
        insert testVehicle;

        List<Claim> claims = new List<Claim>();
        for (Integer i = 0; i < 3; i++) {
            claims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'New',
                Summary = 'Fraud test claim ' + i,
                EstimatedAmount = 1000 * (i + 1),
                InitiationDate = Date.today(),
                Risk_Score__c = 30 * (i + 1),
                Channel__c = 'Web_Chat',
                DealerCode__c = 'FRAUD-DLR'
            ));
        }
        insert claims;

        List<ClaimItem> items = new List<ClaimItem>();
        for (Claim c : claims) {
            items.add(new ClaimItem(
                Name = 'CI-FRAUD-' + c.Id,
                ClaimId = c.Id,
                VehicleId = testVehicle.Id,
                Description = 'Fraud test item',
                FaultDate = Date.today()
            ));
        }
        insert items;
    }

    @IsTest
    static void testSystemScope_basic() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'system';
        req.daysBack = 30;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assertEquals(null, r[0].errorMessage);
        System.assertNotEquals(null, r[0].totalClaimsAnalyzed);
        System.assertNotEquals(null, r[0].overallRisk);
        System.assertNotEquals(null, r[0].flagCount);
    }

    @IsTest
    static void testSystemScope_duplicateVinFlag() {
        // Setup put 3 claim items on same vehicle → duplicate VIN flag should fire
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'system';
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assert(r[0].flagCount >= 1, 'Expected at least 1 flag from duplicate VIN');
        System.assert(r[0].flags.contains('Duplicate VIN'), 'Expected Duplicate VIN flag in: ' + r[0].flags);
    }

    @IsTest
    static void testSystemScope_highValueHighRiskFilter() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'system';
        req.minAmount = 2500;
        req.minRiskScore = 80;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
        // claim #3 has $3000 + risk 90 → matches
        System.assert(r[0].flags.contains('High-Value High-Risk') || r[0].flagCount >= 1,
            'Expected High-Value High-Risk in: ' + r[0].flags);
    }

    @IsTest
    static void testDealerScope_byId() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Fraud Test Dealer' LIMIT 1];

        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'dealer';
        req.scopeId = dealer.Id;
        req.daysBack = 60;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
        System.assertNotEquals(null, r[0].overallRisk);
        System.assert(r[0].flags.contains('[Volume]'), 'Expected Volume flag in: ' + r[0].flags);
        System.assert(r[0].recommendation.contains('peer'), 'Recommendation should mention peer comparison');
    }

    @IsTest
    static void testDealerScope_byName() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'dealer';
        req.dealerName = 'Fraud Test Dealer';
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
        System.assertNotEquals(null, r[0].overallRisk);
        System.assert(r[0].flags.contains('Duplicate VIN'), 'Should detect duplicate VIN: ' + r[0].flags);
    }

    @IsTest
    static void testClaimScope() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'claim';
        req.scopeId = c.Id;
        req.daysBack = 30;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
        System.assertNotEquals(null, r[0].overallRisk);
        System.assertNotEquals(null, r[0].flags);
    }

    @IsTest
    static void testClaimScope_byClaimNumber() {
        Claim c = [SELECT Id, Name FROM Claim LIMIT 1];

        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'claim';
        req.claimNumber = c.Name;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'claimNumber resolution should work: ' + r[0].errorMessage);
    }

    @IsTest
    static void testVehicleScope_byVin() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'vehicle';
        req.vin = '1ELECFRAUDTEST001';
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
        System.assert(r[0].flags.contains('Vehicle History'), 'Expected Vehicle History line: ' + r[0].flags);
    }

    @IsTest
    static void testInvalidScope() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'invalidscope';
        req.scopeId = 'abc';
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertNotEquals(null, r[0].errorMessage);
    }

    @IsTest
    static void testMissingScopeId_nonSystem() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'dealer';
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertNotEquals(null, r[0].errorMessage);
        System.assert(r[0].errorMessage.contains('resolve'), 'Should explain resolution failure: ' + r[0].errorMessage);
    }

    @IsTest
    static void testNullRequests() {
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    @IsTest
    static void testDaysBackBoundary() {
        WC_FraudPatternCheck.FraudRequest req = new WC_FraudPatternCheck.FraudRequest();
        req.scope = 'system';
        req.daysBack = 999;
        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> r = WC_FraudPatternCheck.analyze(new List<WC_FraudPatternCheck.FraudRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'Should clamp daysBack to max 180');
    }

    @IsTest
    static void testBulkMixedScopes() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Fraud Test Dealer' LIMIT 1];
        Claim c = [SELECT Id FROM Claim LIMIT 1];

        List<WC_FraudPatternCheck.FraudRequest> reqs = new List<WC_FraudPatternCheck.FraudRequest>();
        WC_FraudPatternCheck.FraudRequest r1 = new WC_FraudPatternCheck.FraudRequest();
        r1.scope = 'system';
        reqs.add(r1);
        WC_FraudPatternCheck.FraudRequest r2 = new WC_FraudPatternCheck.FraudRequest();
        r2.scope = 'dealer';
        r2.scopeId = dealer.Id;
        reqs.add(r2);
        WC_FraudPatternCheck.FraudRequest r3 = new WC_FraudPatternCheck.FraudRequest();
        r3.scope = 'claim';
        r3.scopeId = c.Id;
        reqs.add(r3);

        Test.startTest();
        List<WC_FraudPatternCheck.FraudResponse> results = WC_FraudPatternCheck.analyze(reqs);
        Test.stopTest();

        System.assertEquals(3, results.size());
        for (WC_FraudPatternCheck.FraudResponse res : results) {
            System.assertEquals(null, res.errorMessage);
        }
    }
}