@IsTest
private class WC_ClaimSummaryTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'Pune Electra Service Center');
        insert d;

        Product2 vdProduct = new Product2(Name = 'ClaimSummary Test Model', ProductCode = 'CS-VEH-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'ClaimSummary Test Def', ProductId = vdProduct.Id);
        insert vd;
        Asset vehicleAsset = new Asset(Name = 'ClaimSummary Test Asset', AccountId = d.Id);
        insert vehicleAsset;
        Vehicle testVehicle = new Vehicle(
            Name = 'ClaimSummary Test Vehicle',
            VehicleIdentificationNumber = '1ELECSUMRY2025001',
            AssetId = vehicleAsset.Id,
            VehicleDefinitionId = vd.Id,
            ExteriorColor = 'Black',
            LastOdometerReading = 10000
        );
        insert testVehicle;

        WarrantyTerm wt = new WarrantyTerm(
            WarrantyTermName = 'CS Test Warranty',
            IsActive = true,
            WarrantyDuration = 36,
            WarrantyUnitOfTime = 'Months',
            UsageCovered = 60000,
            WarrantyType = 'Standard',
            EffectiveStartDate = 'Purchase Date'
        );
        insert wt;
        AssetWarranty aw = new AssetWarranty(
            AssetId = vehicleAsset.Id,
            WarrantyTermId = wt.Id,
            StartDate = Date.today().addYears(-1),
            EndDate = Date.today().addYears(2),
            WarrantyType = 'Standard'
        );
        insert aw;

        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'Under Review',
            Summary = 'Motor fault investigation',
            EstimatedAmount = 1200,
            InitiationDate = Date.today().addDays(-3),
            Risk_Score__c = 40,
            AI_Recommendation__c = 'Review',
            AI_Triage_Notes__c = 'Test triage notes for CS',
            Channel__c = 'Web_Chat',
            DealerCode__c = 'DLR-005'
        );
        insert c;

        ClaimItem ci = new ClaimItem(
            Name = 'CI-CS-001',
            ClaimId = c.Id,
            VehicleId = testVehicle.Id,
            Description = 'Motor replacement',
            Type__c = 'Part',
            EstimatedAmount__c = 1000,
            FaultDate = Date.today().addDays(-3)
        );
        insert ci;
    }

    @IsTest
    static void testQueueMode() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'queue';
        req.limitCount = 5;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assert(!r.isEmpty());
        System.assert(String.isNotBlank(r[0].summary));
    }

    @IsTest
    static void testQueueMode_defaultLimit() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'queue';
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'Default limit should work');
    }

    @IsTest
    static void testSingleMode() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        req.claimId = c.Id;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, r.size());
        System.assertEquals(null, r[0].errorMessage);
        System.assertNotEquals(null, r[0].claimNumber);
        System.assertEquals(40, r[0].riskScore, 'Risk score should match setup');
        System.assert(r[0].daysPending >= 3, 'Initiated 3 days ago');
        System.assertNotEquals(null, r[0].claimItems, 'Claim items section should populate');
    }

    @IsTest
    static void testSingleMode_defaultMode() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.claimId = c.Id; // mode omitted — defaults to 'single'
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage);
    }

    @IsTest
    static void testSingleMode_blankClaimId() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('required'));
    }

    @IsTest
    static void testSingleMode_claimNotFound() {
        Claim tmp = [SELECT Id FROM Claim LIMIT 1];
        Id deletedId = tmp.Id;
        delete tmp;
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        req.claimId = deletedId;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assert(r[0].errorMessage != null && r[0].errorMessage.contains('not found'));
    }

    @IsTest
    static void testAggregateMode() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'aggregate';
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assert(String.isNotBlank(r[0].summary));
        System.assert(r[0].summary.contains('AGGREGATE'));
    }

    @IsTest
    static void testNullRequests() {
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(null);
        Test.stopTest();
        System.assertEquals(0, r.size());
    }

    @IsTest
    static void testSingleMode_invalidIdFormat() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        req.claimId = 'not-a-valid-id';
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertNotEquals(null, r[0].errorMessage, 'Invalid Id format should set errorMessage');
    }

    @IsTest
    static void testSingleMode_vehicleAndWarrantyResolved() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        req.claimId = c.Id;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'Should succeed via IPA→Asset→Vehicle chain');
        System.assertNotEquals(null, r[0].vehicleInfo, 'vehicleInfo must populate via 2-step IPA lookup');
        System.assert(r[0].vehicleInfo.contains('1ELECSUMRY2025001'), 'VIN must appear in vehicleInfo');
        System.assertNotEquals(null, r[0].warrantyInfo, 'warrantyInfo must populate');
        System.assert(!r[0].warrantyInfo.contains('No active'), 'Active warranty should be found');
    }

    @IsTest
    static void testQueueMode_vehicleResolvedViaIPA() {
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'queue';
        req.limitCount = 5;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assert(!r.isEmpty(), 'Queue must return results');
        System.assertEquals(null, r[0].errorMessage, 'No error expected in queue mode');
        System.assertNotEquals(null, r[0].summary, 'Summary must be non-null');
    }

    @IsTest
    static void testSingleMode_byClaimNumber() {
        Claim c = [SELECT Id, Name FROM Claim LIMIT 1];
        WC_ClaimSummary.SummaryRequest req = new WC_ClaimSummary.SummaryRequest();
        req.mode = 'single';
        req.claimNumber = c.Name;
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> r = WC_ClaimSummary.summarize(new List<WC_ClaimSummary.SummaryRequest>{ req });
        Test.stopTest();
        System.assertEquals(null, r[0].errorMessage, 'claimNumber-only path should resolve: ' + r[0].errorMessage);
        System.assertEquals(c.Name, r[0].claimNumber);
    }

    @IsTest
    static void testBulkMixedModes() {
        Claim c = [SELECT Id FROM Claim LIMIT 1];
        List<WC_ClaimSummary.SummaryRequest> reqs = new List<WC_ClaimSummary.SummaryRequest>();
        WC_ClaimSummary.SummaryRequest r1 = new WC_ClaimSummary.SummaryRequest();
        r1.mode = 'queue';
        reqs.add(r1);
        WC_ClaimSummary.SummaryRequest r2 = new WC_ClaimSummary.SummaryRequest();
        r2.mode = 'aggregate';
        reqs.add(r2);
        WC_ClaimSummary.SummaryRequest r3 = new WC_ClaimSummary.SummaryRequest();
        r3.mode = 'single';
        r3.claimId = c.Id;
        reqs.add(r3);
        Test.startTest();
        List<WC_ClaimSummary.SummaryResponse> results = WC_ClaimSummary.summarize(reqs);
        Test.stopTest();
        System.assertEquals(3, results.size());
    }
}