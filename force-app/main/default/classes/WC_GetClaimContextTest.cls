@IsTest
private class WC_GetClaimContextTest {

    @TestSetup
    static void setupTestData() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
        insert dealer;

        Asset vehicleAsset = new Asset(Name = 'Electra Bolt EV - BOLT001', AccountId = dealer.Id);
        insert vehicleAsset;

        Product2 vdProduct = new Product2(Name = 'Electra Bolt 2025 Model', ProductCode = 'EB-CTX-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'Electra Bolt 2025', ProductId = vdProduct.Id);
        insert vd;

        Vehicle testVehicle = new Vehicle(
            Name = 'Electra Bolt EV 2025',
            VehicleIdentificationNumber = '1ELEC2025BOLT0001',
            AssetId = vehicleAsset.Id,
            VehicleDefinitionId = vd.Id,
            ExteriorColor = 'Midnight Blue',
            LastOdometerReading = 45200
        );
        insert testVehicle;

        WarrantyTerm basicTerm = new WarrantyTerm(
            WarrantyTermName = 'Basic Vehicle Warranty',
            IsActive = true,
            WarrantyDuration = 36,
            WarrantyUnitOfTime = 'Months',
            UsageCovered = 60000,
            WarrantyType = 'Standard',
            EffectiveStartDate = 'Purchase Date'
        );
        insert basicTerm;

        AssetWarranty activeWarranty = new AssetWarranty(
            AssetId = vehicleAsset.Id,
            WarrantyTermId = basicTerm.Id,
            StartDate = Date.today().addYears(-1),
            EndDate = Date.today().addYears(2),
            WarrantyType = 'Basic'
        );
        insert activeWarranty;

        Claim testClaim = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'New',
            Summary = 'Battery module not charging past 60%',
            EstimatedAmount = 2500.00,
            InitiationDate = Date.today(),
            Channel__c = 'Web_Chat',
            FailureDescription__c = 'Battery module fails to charge beyond 60% capacity',
            DiagnosticTroubleCode__c = 'P0A80',
            MileageAtClaim__c = 45200,
            DealerCode__c = 'DLR-001',
            Risk_Score__c = 15,
            AI_Recommendation__c = 'Auto-Approved: Low risk score 15',
            AI_Triage_Notes__c = 'Valid warranty, low mileage, known part'
        );
        insert testClaim;

        List<ClaimItem> items = new List<ClaimItem>{
            new ClaimItem(
                Name = 'CI-CTX-001',
                ClaimId = testClaim.Id,
                Description = 'EV Battery Module Assembly',
                Type__c = 'Part',
                CausalPartNumber__c = 'BAT-MOD-001',
                Quantity__c = 1,
                UnitPrice__c = 2000.00,
                EstimatedAmount__c = 2000.00,
                FaultDate = Date.today()
            ),
            new ClaimItem(
                Name = 'CI-CTX-002',
                ClaimId = testClaim.Id,
                Description = 'Battery replacement labor',
                FaultDate = Date.today(),
                Type__c = 'Labor',
                LaborHours__c = 3.5,
                EstimatedAmount__c = 500.00
            )
        };
        insert items;
    }

    @IsTest
    static void testValidClaimWithFullContext() {
        Claim testClaim = [SELECT Id FROM Claim LIMIT 1];

        WC_GetClaimContext.Input inp = new WC_GetClaimContext.Input();
        inp.claimId = testClaim.Id;

        Test.startTest();
        List<WC_GetClaimContext.Output> results =
            WC_GetClaimContext.getClaimContext(new List<WC_GetClaimContext.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        WC_GetClaimContext.Output out = results[0];

        System.assert(out.VehicleInfo.contains('not available') || out.VehicleInfo.contains('no asset'), 'Should indicate no vehicle linked');
        System.assert(out.WarrantyInfo.contains('No warranty data') || out.WarrantyInfo.contains('no asset'), 'Should indicate no warranty data');

        System.assert(out.ClaimItemsInfo.contains('EV Battery Module'), 'Should contain part description');
        System.assert(out.ClaimItemsInfo.contains('BAT-MOD-001'), 'Should contain part number');
        System.assert(out.ClaimItemsInfo.contains('Labor'), 'Should contain labor item');
        System.assert(out.ClaimItemsInfo.contains('3.5'), 'Should contain labor hours');

        System.assert(out.DealerContext.contains('Bay Area Electra Motors'), 'Should contain dealer name');
        System.assert(out.DealerContext.contains('DLR-001'), 'Should contain dealer code');

        System.assert(out.TriageInfo.contains('15/100'), 'Should contain risk score');
        System.assert(out.TriageInfo.contains('Auto-Approved'), 'Should contain recommendation');
    }

    @IsTest
    static void testClaimNotFound() {
        Claim tempClaim = [SELECT Id FROM Claim LIMIT 1];
        Id validClaimId = tempClaim.Id;
        delete tempClaim;

        WC_GetClaimContext.Input inp = new WC_GetClaimContext.Input();
        inp.claimId = validClaimId;

        Test.startTest();
        List<WC_GetClaimContext.Output> results =
            WC_GetClaimContext.getClaimContext(new List<WC_GetClaimContext.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Claim not found', results[0].VehicleInfo);
    }

    @IsTest
    static void testClaimWithNoAsset() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];

        Claim noAssetClaim = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'New',
            Summary = 'Claim without vehicle link',
            InitiationDate = Date.today()
        );
        insert noAssetClaim;

        WC_GetClaimContext.Input inp = new WC_GetClaimContext.Input();
        inp.claimId = noAssetClaim.Id;

        Test.startTest();
        List<WC_GetClaimContext.Output> results =
            WC_GetClaimContext.getClaimContext(new List<WC_GetClaimContext.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].VehicleInfo.contains('not available'), 'Should indicate no vehicle');
        System.assert(results[0].WarrantyInfo.contains('No warranty data'), 'Should indicate no warranty');
    }

    @IsTest
    static void testBulkProcessing() {
        Claim testClaim = [SELECT Id FROM Claim LIMIT 1];

        List<WC_GetClaimContext.Input> inputs = new List<WC_GetClaimContext.Input>();
        for (Integer i = 0; i < 10; i++) {
            WC_GetClaimContext.Input inp = new WC_GetClaimContext.Input();
            inp.claimId = testClaim.Id;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_GetClaimContext.Output> results = WC_GetClaimContext.getClaimContext(inputs);
        Test.stopTest();

        System.assertEquals(10, results.size());
        for (WC_GetClaimContext.Output out : results) {
            System.assertNotEquals(null, out.VehicleInfo, 'All should have VehicleInfo populated');
        }
    }

    @IsTest
    static void testEmptyInput() {
        WC_GetClaimContext.Input inp = new WC_GetClaimContext.Input();
        inp.claimId = '';

        Test.startTest();
        List<WC_GetClaimContext.Output> results =
            WC_GetClaimContext.getClaimContext(new List<WC_GetClaimContext.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].VehicleInfo.contains('Invalid'), 'Should indicate invalid input');
    }
}