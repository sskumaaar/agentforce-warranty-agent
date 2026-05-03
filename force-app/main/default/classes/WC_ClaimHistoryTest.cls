@IsTest
private class WC_ClaimHistoryTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'Bay Area Electra Motors');
        insert d;

        Product2 vdProduct = new Product2(Name = 'History Test Model', ProductCode = 'HIST-VEH-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'History Test Def', ProductId = vdProduct.Id);
        insert vd;
        Asset asset = new Asset(Name = 'History Test Asset', AccountId = d.Id);
        insert asset;
        Vehicle v = new Vehicle(
            Name = 'History Test Vehicle',
            VehicleIdentificationNumber = '1ELECHIST2025T001',
            AssetId = asset.Id,
            VehicleDefinitionId = vd.Id
        );
        insert v;

        List<Claim> claims = new List<Claim>{
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id,
                Status = 'Approved',
                Summary = 'Approved history test',
                EstimatedAmount = 99,
                InitiationDate = Date.today().addDays(-5),
                Channel__c = 'Portal',
                DealerCode__c = 'DLR-001'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id,
                Status = 'Denied',
                Summary = 'Denied history test',
                EstimatedAmount = 500,
                InitiationDate = Date.today().addDays(-3),
                Channel__c = 'Portal',
                DealerCode__c = 'DLR-001'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id,
                Status = 'New',
                Summary = 'Open history test',
                EstimatedAmount = 250,
                InitiationDate = Date.today().addDays(-1),
                Channel__c = 'Portal',
                DealerCode__c = 'DLR-001'
            )
        };
        insert claims;

        // Link first claim to vehicle via ClaimItem
        ClaimItem ci = new ClaimItem(
            Name = 'CI-HIST-001',
            ClaimId = claims[0].Id,
            VehicleId = v.Id,
            Description = 'History vehicle link',
            FaultDate = Date.today().addDays(-5)
        );
        insert ci;
    }

    @IsTest
    static void testDealerHistory() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        req.accountId = a.Id;
        req.daysBack = 90;
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assertEquals(3, r[0].totalClaims);
        System.assertNotEquals(null, r[0].approvalRate, 'Approval rate should calculate');
        System.assert(r[0].claims.contains('WC-TEST-CH-001'));
    }

    @IsTest
    static void testDealerHistory_defaultDaysBack() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        req.accountId = a.Id;
        // daysBack omitted — defaults to 90
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
    }

    @IsTest
    static void testDealerHistory_missingAccountId() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        // accountId AND dealerName missing
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('Account Id'));
    }

    @IsTest
    static void testDealerHistory_byDealerName() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        req.dealerName = 'Bay Area Electra Motors';
        req.daysBack = 30;
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'dealerName resolution should work: ' + r[0].errorMessage);
        System.assert(r[0].totalClaims >= 1, 'Should find seeded dealer claims');
    }

    @IsTest
    static void testDealerHistory_unknownDealerName() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        req.dealerName = 'Nonexistent Dealer XYZ';
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('Account Id'),
            'Unknown dealer name should fall through to required-field error');
    }

    @IsTest
    static void testVehicleHistory() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'vehicle';
        req.vin = '1ELECHIST2025T001';
        req.daysBack = 30;
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assertEquals(1, r[0].totalClaims, 'One claim linked via ClaimItem');
    }

    @IsTest
    static void testVehicleHistory_vinNotFound() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'vehicle';
        req.vin = 'NONEXISTENTVIN99';
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(0, r[0].totalClaims);
        System.assert(r[0].claims.contains('No') && r[0].claims.contains('vehicle'));
    }

    @IsTest
    static void testVehicleHistory_missingVin() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'vehicle';
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('VIN'));
    }

    @IsTest
    static void testVehicleHistory_noClaimsLinked() {
        // Create vehicle with no claim items
        Account d = [SELECT Id FROM Account LIMIT 1];
        Product2 vdProduct = new Product2(Name = 'Lonely Vehicle Model', ProductCode = 'LONE-VEH-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'Lonely Vehicle Def', ProductId = vdProduct.Id);
        insert vd;
        Asset asset = new Asset(Name = 'Lonely Vehicle Asset', AccountId = d.Id);
        insert asset;
        Vehicle v = new Vehicle(
            Name = 'Lonely Vehicle',
            VehicleIdentificationNumber = '1ELECLONELY000001',
            AssetId = asset.Id,
            VehicleDefinitionId = vd.Id
        );
        insert v;

        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'vehicle';
        req.vin = '1ELECLONELY000001';
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(0, r[0].totalClaims);
        System.assert(r[0].claims.contains('No claims'));
    }

    @IsTest
    static void testInvalidLookupType() {
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'invalid';
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('vehicle or dealer'));
    }

    @IsTest
    static void testNullRequests() {
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    @IsTest
    static void testDaysBackBoundary() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        WC_ClaimHistory.HistoryRequest req = new WC_ClaimHistory.HistoryRequest();
        req.lookupType = 'dealer';
        req.accountId = a.Id;
        req.daysBack = 9999; // > 730 max → should clamp
        Test.startTest();
        List<WC_ClaimHistory.HistoryResponse> r = WC_ClaimHistory.loadHistory(new List<WC_ClaimHistory.HistoryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
    }
}