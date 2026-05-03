@isTest
private class WC_WarrantyCheckTest {

    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
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
            EndDate = Date.today().addYears(7),
            LaborCovered = 100,
            PartsCovered = 100
        );
        insert aw;

        Asset expiredAsset = new Asset(
            Name = '2020 Electra Bolt Expired Asset',
            AccountId = dealer.Id
        );
        insert expiredAsset;

        Vehicle expiredVehicle = new Vehicle(
            Name = '2020 Electra Bolt Expired',
            VehicleIdentificationNumber = '1ELEC2020BOLT0099',
            VehicleDefinitionId = vd.Id,
            AssetId = expiredAsset.Id
        );
        insert expiredVehicle;

        AssetWarranty expiredAw = new AssetWarranty(
            AssetId = expiredAsset.Id,
            WarrantyTermId = wt.Id,
            StartDate = Date.today().addYears(-5),
            EndDate = Date.today().addDays(-30)
        );
        insert expiredAw;
    }

    @isTest
    static void testActiveWarranty_WithinMileage() {
        WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.currentMileage = 30000;

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(
            new List<WC_WarrantyCheck.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_WarrantyCheck.Output out = results[0];
        Assert.isTrue(out.isCovered);
        Assert.isTrue(out.mileageWithinLimit);
        Assert.isTrue(out.daysRemaining > 0);
        Assert.areEqual('EV Battery 8yr', out.warrantyTermName);
        Assert.isNotNull(out.warrantyId);
    }

    @isTest
    static void testActiveWarranty_MileageExceeded() {
        WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.currentMileage = 200000;

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(
            new List<WC_WarrantyCheck.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].isCovered);
        Assert.isFalse(results[0].mileageWithinLimit);
        Assert.isTrue(results[0].denialReason.contains('Mileage'));
    }

    @isTest
    static void testExpiredWarranty() {
        WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
        inp.vinNumber = '1ELEC2020BOLT0099';

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(
            new List<WC_WarrantyCheck.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].isCovered);
        Assert.isTrue(results[0].denialReason.contains('No active warranty'));
    }

    @isTest
    static void testVehicleNotFound() {
        WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
        inp.vinNumber = 'DOESNOTEXIST00000';

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(
            new List<WC_WarrantyCheck.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].isCovered);
        Assert.isTrue(results[0].denialReason.contains('Vehicle not found'));
    }

    @isTest
    static void testBulk_200Records() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WarrantyTerm wt = [SELECT Id FROM WarrantyTerm WHERE WarrantyTermName = 'EV Battery 8yr' LIMIT 1];

        List<Asset> assets = new List<Asset>();
        for (Integer i = 0; i < 200; i++) {
            assets.add(new Asset(
                Name = 'Bulk Warranty Asset ' + i,
                AccountId = dealer.Id
            ));
        }
        insert assets;

        VehicleDefinition vd2 = [SELECT Id FROM VehicleDefinition LIMIT 1];
        List<Vehicle> vehicles = new List<Vehicle>();
        for (Integer i = 0; i < 200; i++) {
            // [v22.1] Canonical 17-char VIN: 1ELECWCHKBULK (13) + 4-digit seq.
            String seq = String.valueOf(i).leftPad(4, '0');
            vehicles.add(new Vehicle(
                Name = 'Bulk Warranty Vehicle ' + seq,
                VehicleIdentificationNumber = '1ELECWCHKBULK' + seq,
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

        List<WC_WarrantyCheck.Input> inputs = new List<WC_WarrantyCheck.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
            String seq = String.valueOf(i).leftPad(4, '0');
            inp.vinNumber = '1ELECWCHKBULK' + seq;
            inp.currentMileage = 50000;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        for (WC_WarrantyCheck.Output out : results) {
            Assert.isTrue(out.isCovered);
        }
    }

    @isTest
    static void testNullMileage_SkipsMileageCheck() {
        WC_WarrantyCheck.Input inp = new WC_WarrantyCheck.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.currentMileage = null;

        Test.startTest();
        List<WC_WarrantyCheck.Output> results = WC_WarrantyCheck.execute(
            new List<WC_WarrantyCheck.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].isCovered);
        Assert.isTrue(results[0].mileageWithinLimit);
    }
}