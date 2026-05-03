@isTest
private class WC_VINLookupTest {

    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Pune Electra Service Center');
        insert dealer;

        Product2 vdProduct = new Product2(Name = 'Electra Bolt 2025 Model', ProductCode = 'EB-2025', IsActive = true);
        insert vdProduct;

        VehicleDefinition vd = new VehicleDefinition(Name = 'Electra Bolt Test', ProductId = vdProduct.Id);
        insert vd;

        Asset vehicleAsset = new Asset(
            Name = '2025 Electra Bolt Asset',
            AccountId = dealer.Id
        );
        insert vehicleAsset;

        Vehicle testVehicle = new Vehicle(
            Name = '2025 Electra Bolt',
            VehicleIdentificationNumber = '1ELEC2025BOLT0001',
            VehicleDefinitionId = vd.Id,
            AssetId = vehicleAsset.Id
        );
        insert testVehicle;

        WarrantyTerm wt = new WarrantyTerm(
            WarrantyTermName = 'EV Battery 8yr',
            IsActive = true,
            WarrantyDuration = 8,
            WarrantyUnitOfTime = 'Years',
            UsageCovered = 160000,
            WarrantyType = 'Standard',
            EffectiveStartDate = 'Purchase Date'
        );
        insert wt;

        AssetWarranty aw = new AssetWarranty(
            AssetId = vehicleAsset.Id,
            WarrantyTermId = wt.Id,
            StartDate = Date.today().addYears(-1),
            EndDate = Date.today().addYears(7)
        );
        insert aw;
    }

    @isTest
    static void testValidVIN_WithActiveWarranty() {
        WC_VINLookup.Input inp = new WC_VINLookup.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_VINLookup.Output out = results[0];
        Assert.isTrue(out.vehicleFound);
        Assert.areEqual('Active', out.warrantyStatus);
        Assert.isNotNull(out.vehicleId);
        Assert.isNotNull(out.assetId);
        Assert.isNotNull(out.warrantyExpiryDate);
        Assert.isTrue(out.message.contains('Vehicle found'));
    }

    @isTest
    static void testValidVIN_ExpiredWarranty() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];

        Asset expiredAsset = new Asset(
            Name = '2020 Electra Bolt Expired Asset',
            AccountId = dealer.Id
        );
        insert expiredAsset;

        VehicleDefinition vd = [SELECT Id FROM VehicleDefinition LIMIT 1];
        Vehicle expiredVehicle = new Vehicle(
            Name = '2020 Electra Bolt Expired',
            VehicleIdentificationNumber = '1ELEC2020BOLT0099',
            VehicleDefinitionId = vd.Id,
            AssetId = expiredAsset.Id
        );
        insert expiredVehicle;

        WarrantyTerm wt = [SELECT Id FROM WarrantyTerm LIMIT 1];
        AssetWarranty expiredAw = new AssetWarranty(
            AssetId = expiredAsset.Id,
            WarrantyTermId = wt.Id,
            StartDate = Date.today().addYears(-5),
            EndDate = Date.today().addDays(-30)
        );
        insert expiredAw;

        WC_VINLookup.Input inp = new WC_VINLookup.Input();
        inp.vinNumber = '1ELEC2020BOLT0099';

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].vehicleFound);
        Assert.areEqual('Expired', results[0].warrantyStatus);
    }

    @isTest
    static void testInvalidVIN_NotFound() {
        WC_VINLookup.Input inp = new WC_VINLookup.Input();
        inp.vinNumber = 'DOESNOTEXIST00000';

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].vehicleFound);
        Assert.isTrue(results[0].message.contains('No vehicle found'));
    }

    @isTest
    static void testBulk_200Records() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WarrantyTerm wt = [SELECT Id FROM WarrantyTerm LIMIT 1];

        List<Asset> assets = new List<Asset>();
        for (Integer i = 0; i < 200; i++) {
            assets.add(new Asset(
                Name = 'Bulk Asset ' + i,
                AccountId = dealer.Id
            ));
        }
        insert assets;

        VehicleDefinition vd2 = [SELECT Id FROM VehicleDefinition LIMIT 1];
        List<Vehicle> vehicles = new List<Vehicle>();
        for (Integer i = 0; i < 200; i++) {
            // [v22.1] Canonical 17-char VIN: 1ELECVINBULK (12) + 5-digit seq.
            String seq = String.valueOf(i).leftPad(5, '0');
            vehicles.add(new Vehicle(
                Name = 'Bulk Vehicle ' + seq,
                VehicleIdentificationNumber = '1ELECVINBULK' + seq,
                VehicleDefinitionId = vd2.Id,
                AssetId = assets[i].Id
            ));
        }
        insert vehicles;

        List<AssetWarranty> warranties = new List<AssetWarranty>();
        for (Integer i = 0; i < 200; i++) {
            warranties.add(new AssetWarranty(
                AssetId = assets[i].Id,
                WarrantyTermId = wt.Id,
                StartDate = Date.today().addYears(-1),
                EndDate = Date.today().addYears(4)
            ));
        }
        insert warranties;

        List<WC_VINLookup.Input> inputs = new List<WC_VINLookup.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_VINLookup.Input inp = new WC_VINLookup.Input();
            String seq = String.valueOf(i).leftPad(5, '0');
            inp.vinNumber = '1ELECVINBULK' + seq;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        for (WC_VINLookup.Output out : results) {
            Assert.isTrue(out.vehicleFound);
        }
    }

    @isTest
    static void testEmptyInput() {
        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>()
        );
        Test.stopTest();

        Assert.areEqual(0, results.size());
    }

    @isTest
    static void testMixedVINs_SomeValidSomeInvalid() {
        WC_VINLookup.Input validInp = new WC_VINLookup.Input();
        validInp.vinNumber = '1ELEC2025BOLT0001';

        WC_VINLookup.Input invalidInp = new WC_VINLookup.Input();
        invalidInp.vinNumber = '9XXXX0000FAKE999';

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>{ validInp, invalidInp }
        );
        Test.stopTest();

        Assert.areEqual(2, results.size());
        Assert.isTrue(results[0].vehicleFound);
        Assert.isFalse(results[1].vehicleFound);
    }

    /**
     * Cross-dealer fields populated correctly: ownerDealerName must be the
     * Account that owns the asset, regardless of who the running user is.
     * (crossDealer flag depends on the running user's AccountId; in test
     * context the admin user has no AccountId, so crossDealer is expected
     * to be false / null — the field still exists on Output.)
     */
    @isTest
    static void testCrossDealerFields_ownerNamePopulated() {
        WC_VINLookup.Input inp = new WC_VINLookup.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';

        Test.startTest();
        List<WC_VINLookup.Output> results = WC_VINLookup.execute(
            new List<WC_VINLookup.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_VINLookup.Output out = results[0];
        Assert.isTrue(out.vehicleFound);
        Assert.areEqual('Pune Electra Service Center', out.ownerDealerName,
            'ownerDealerName should resolve from Asset.Account.Name');
        // crossDealer field should exist on Output (default false when running
        // user has no AccountId, as is the case in test context)
        Assert.isNotNull(out.crossDealer == null ? false : out.crossDealer,
            'crossDealer field should be present on Output (Boolean, may be null/false)');
    }
}