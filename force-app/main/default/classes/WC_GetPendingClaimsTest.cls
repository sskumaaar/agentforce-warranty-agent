@IsTest
private class WC_GetPendingClaimsTest {

    @TestSetup
    static void setupTestData() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
        insert dealer;

        Asset vehicleAsset = new Asset(Name = 'Electra Bolt EV - BOLT001', AccountId = dealer.Id);
        insert vehicleAsset;

        Product2 vdProduct = new Product2(Name = 'Electra Bolt 2025 Model', ProductCode = 'EB-PC-2025', IsActive = true);
        insert vdProduct;
        VehicleDefinition vd = new VehicleDefinition(Name = 'Electra Bolt 2025', ProductId = vdProduct.Id);
        insert vd;

        Vehicle testVehicle = new Vehicle(
            Name = 'Electra Bolt EV 2025',
            VehicleIdentificationNumber = '1ELEC2025BOLT0001',
            AssetId = vehicleAsset.Id,
            VehicleDefinitionId = vd.Id
        );
        insert testVehicle;

        List<Claim> claims = new List<Claim>{
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'New', Summary = 'Brake controller failure',
                EstimatedAmount = 45000, InitiationDate = Date.today(),
                Risk_Score__c = 85, AI_Recommendation__c = 'Investigate',
                Channel__c = 'Web_Chat', DealerCode__c = 'DLR-001'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Under Review', Summary = 'Battery module issue',
                EstimatedAmount = 250000, InitiationDate = Date.today().addDays(-2),
                Risk_Score__c = 35, AI_Recommendation__c = 'Review',
                Channel__c = 'Web_Chat', DealerCode__c = 'DLR-001'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'New', Summary = 'Brake pad replacement',
                EstimatedAmount = 8500, InitiationDate = Date.today().addDays(-1),
                Risk_Score__c = 5, AI_Recommendation__c = 'Auto-Approve',
                Channel__c = 'Portal', DealerCode__c = 'DLR-001'
            )
        };
        insert claims;
    }

    @IsTest
    static void testGetAllPending() {
        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results.size());
        WC_GetPendingClaims.Output out = results[0];
        System.assert(out.claimsFound, 'Should find pending claims');
        System.assertEquals(3, out.totalCount);
        System.assert(out.claimsSummary.contains('Investigate'), 'Highest risk should appear');
        System.assert(out.totalEstimatedAmount > 0, 'Amount should be positive');
    }

    @IsTest
    static void testFilterByStatus() {
        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();
        inp.statusFilter = 'Under Review';

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results[0].totalCount);
    }

    @IsTest
    static void testNoPendingClaims() {
        delete [SELECT Id FROM Claim];

        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assert(!results[0].claimsFound, 'Should find no claims');
        System.assert(results[0].message.contains('clear'), 'Should indicate queue is clear');
    }

    @IsTest
    static void testMaxResults() {
        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();
        inp.maxResults = 1;

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assertEquals(1, results[0].totalCount);
    }

    @IsTest
    static void testAgingSortMode() {
        // Add an old claim → should appear first when sortMode=aging
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        insert new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'Submitted', Summary = 'Old claim',
            EstimatedAmount = 100, InitiationDate = Date.today().addDays(-10),
            Risk_Score__c = 10, AI_Recommendation__c = 'Auto-Approve',
            Channel__c = 'Portal', DealerCode__c = 'DLR-001'
        );

        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();
        inp.sortMode = 'aging';

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        WC_GetPendingClaims.Output out = results[0];
        System.assert(out.claimsFound);
        System.assert(out.slaBreachCount >= 1, 'Old claim should breach SLA: ' + out.message);
        System.assert(out.claimsSummary.startsWith('1. '), 'Output should be numbered list');
        System.assert(out.claimsSummary.contains('SLA BREACH') || out.claimsSummary.contains('SLA Warning'),
            'SLA tag should appear: ' + out.claimsSummary);
    }

    @IsTest
    static void testTriageNotesSurface() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'Submitted', Summary = 'Triage test',
            EstimatedAmount = 500, InitiationDate = Date.today(),
            Risk_Score__c = 75, AI_Recommendation__c = 'Investigate',
            AI_Triage_Notes__c = 'High part wear suggests deeper electrical fault.',
            Channel__c = 'Web_Chat', DealerCode__c = 'DLR-001'
        );
        insert c;

        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();
        inp.statusFilter = 'Submitted';

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assert(results[0].claimsSummary.contains('Triage:'),
            'Triage notes should be surfaced: ' + results[0].claimsSummary);
    }

    @IsTest
    static void testStatusUnification() {
        // Add Submitted and Requested Information — should be included by default
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        insert new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'Submitted', Summary = 'New submitted',
            EstimatedAmount = 100, InitiationDate = Date.today(),
            Risk_Score__c = 50, Channel__c = 'Portal', DealerCode__c = 'DLR-001'
        );
        insert new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'Requested Information', Summary = 'Awaiting info',
            EstimatedAmount = 100, InitiationDate = Date.today(),
            Risk_Score__c = 50, Channel__c = 'Portal', DealerCode__c = 'DLR-001'
        );

        WC_GetPendingClaims.Input inp = new WC_GetPendingClaims.Input();

        Test.startTest();
        List<WC_GetPendingClaims.Output> results =
            WC_GetPendingClaims.getPendingClaims(new List<WC_GetPendingClaims.Input>{ inp });
        Test.stopTest();

        System.assertEquals(5, results[0].totalCount, 'Should include 3 setup + 2 new across all 4 pending statuses');
    }
}