@isTest
private class WC_ClaimStatusTest {

    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Chennai Electra Works');
        insert dealer;

        Product2 vdProduct = new Product2(Name = 'Electra Storm 2025 Model', ProductCode = 'ES-2025', IsActive = true);
        insert vdProduct;

        VehicleDefinition vd = new VehicleDefinition(Name = 'Electra Storm Test', ProductId = vdProduct.Id);
        insert vd;

        Asset vehicleAsset = new Asset(
            Name = '2025 Electra Storm SUV Asset',
            AccountId = dealer.Id
        );
        insert vehicleAsset;

        Vehicle testVehicle = new Vehicle(
            Name = '2025 Electra Storm SUV',
            VehicleIdentificationNumber = '1ELEC2025STRM0001',
            VehicleDefinitionId = vd.Id,
            AssetId = vehicleAsset.Id
        );
        insert testVehicle;

        Claim testClaim = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Summary = 'Regenerative brake controller fault under warranty',
            Severity = 'Medium',
            InitiationDate = Date.today(),
            Status = 'New'
        );
        insert testClaim;

        ClaimItem testItem = new ClaimItem(
            Name = 'CI-TEST-001',
            ClaimId = testClaim.Id,
            VehicleId = testVehicle.Id,
            Description = 'Regenerative brake controller fault',
            FaultDate = Date.today()
        );
        insert testItem;
    }

    @isTest
    static void testLookupByClaimNumber() {
        Claim existing = [SELECT Name FROM Claim LIMIT 1];

        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
        inp.claimNumber = existing.Name;

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_ClaimStatus.Output out = results[0];
        Assert.isTrue(out.found);
        Assert.areEqual(existing.Name, out.claimNumber);
        Assert.isNotNull(out.status);
        Assert.isTrue(out.message.contains(existing.Name));
    }

    @isTest
    static void testLookupByVIN() {
        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
        inp.vinNumber = '1ELEC2025STRM0001';

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].found);
        Assert.areEqual(1, results[0].totalClaimsFound);
    }

    @isTest
    static void testLookupByDealerAccount() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Chennai Electra Works' LIMIT 1];

        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
        inp.dealerAccountId = dealer.Id;

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].found);
    }

    @isTest
    static void testClaimNotFound() {
        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
        inp.claimNumber = 'CLM-NONEXISTENT';

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].found);
        Assert.isTrue(results[0].message.contains('No claims found'));
    }

    @isTest
    static void testMultipleClaimsForVIN() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Chennai Electra Works' LIMIT 1];
        Vehicle testVehicle = [SELECT Id FROM Vehicle WHERE VehicleIdentificationNumber = '1ELEC2025STRM0001' LIMIT 1];

        List<Claim> additionalClaims = new List<Claim>();
        for (Integer i = 0; i < 2; i++) {
            additionalClaims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Summary = 'Additional warranty claim ' + (i + 1),
                Severity = 'Low',
                InitiationDate = Date.today().addDays(-i),
                Status = 'New'
            ));
        }
        insert additionalClaims;

        List<ClaimItem> items = new List<ClaimItem>();
        Integer idx = 0;
        for (Claim c : additionalClaims) {
            items.add(new ClaimItem(Name = 'CI-MULTI-' + idx, ClaimId = c.Id, VehicleId = testVehicle.Id, FaultDate = Date.today()));
            idx++;
        }
        insert items;

        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
        inp.vinNumber = '1ELEC2025STRM0001';

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].found);
        Assert.areEqual(3, results[0].totalClaimsFound);
        Assert.isNotNull(results[0].claimsSummary);
    }

    @isTest
    static void testBulk_200() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];

        List<Claim> bulkClaims = new List<Claim>();
        for (Integer i = 0; i < 200; i++) {
            bulkClaims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Summary = 'Bulk status test claim ' + i,
                Status = 'New',
                InitiationDate = Date.today()
            ));
        }
        insert bulkClaims;

        List<Claim> insertedClaims = [SELECT Name FROM Claim ORDER BY Name];

        List<WC_ClaimStatus.Input> inputs = new List<WC_ClaimStatus.Input>();
        for (Claim c : insertedClaims) {
            WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();
            inp.claimNumber = c.Name;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(inputs);
        Test.stopTest();

        Assert.areEqual(inputs.size(), results.size());
        for (WC_ClaimStatus.Output out : results) {
            Assert.isTrue(out.found);
        }
    }

    @isTest
    static void testNoLookupFieldsProvided() {
        WC_ClaimStatus.Input inp = new WC_ClaimStatus.Input();

        Test.startTest();
        List<WC_ClaimStatus.Output> results = WC_ClaimStatus.execute(
            new List<WC_ClaimStatus.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].found);
        Assert.isTrue(results[0].message.contains('Please provide'));
    }
}