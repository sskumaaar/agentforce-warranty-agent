@IsTest
private class WC_ClaimTriageServiceTest {
    private class TriageGraph {
        Id accountId;
        Id assetId;
        Id vehicleId;
        Id partProductId;
        Id warrantyTermId;
    }

    private static TriageGraph buildGraph(Boolean recallOpen, Decimal estAmount, Decimal mileage, Boolean activeWarranty) {
        TriageGraph g = new TriageGraph();
        Account acct = new Account(Name = 'Pune Electra Service Center', Type = 'Partner');
        insert acct;
        g.accountId = acct.Id;

        Product2 vProd = new Product2(
            Name = 'Electra Triage Test Vehicle',
            ProductCode = 'VHCL-TRIAGE-TST-' + String.valueOf(Crypto.getRandomInteger()),
            IsActive = true
        );
        Product2 pProd = new Product2(
            Name = 'EV Brake Pad Kit',
            ProductCode = 'P-BPAD-TRI-' + String.valueOf(Crypto.getRandomInteger()),
            IsActive = true
        );
        insert new List<Product2>{ vProd, pProd };
        g.partProductId = pProd.Id;

        VehicleDefinition vd = new VehicleDefinition(
            Name = 'TriageTestVD' + String.valueOf(Crypto.getRandomInteger()),
            ProductId = vProd.Id,
            ModelCode = vProd.ProductCode,
            VariantName = 'Bolt',
            BodyType = 'Sedan',
            FuelType = 'Battery'
        );
        insert vd;

        Asset ast = new Asset(
            Name = 'Triage Asset',
            AccountId = acct.Id,
            Product2Id = vProd.Id,
            // [v22.1] Canonical 17-char VIN: 1ELEC2026TST (12) + 5-digit modular random.
            SerialNumber = '1ELEC2026TST' + String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 100000)).leftPad(5, '0')
        );
        insert ast;
        g.assetId = ast.Id;

        Vehicle veh = new Vehicle(
            Name = 'Triage Vehicle',
            VehicleIdentificationNumber = ast.SerialNumber,
            VehicleDefinitionId = vd.Id,
            AssetId = ast.Id,
            CurrentOwnerId = acct.Id,
            LastOdometerReading = mileage,
            IsRecallOpen = recallOpen,
            Status = 'At Dealer Location',
            ManufacturedDate = Date.newInstance(2026, 1, 1)
        );
        insert veh;
        g.vehicleId = veh.Id;

        WarrantyTerm wt = new WarrantyTerm(
            WarrantyTermName = 'Triage Test Term',
            Code = 'TST-TRI-' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            WarrantyType = 'Standard',
            WarrantyDuration = 36,
            WarrantyUnitOfTime = 'Months',
            UsageCovered = 60000,
            LaborCovered = 100,
            LaborCoveredDuration = 36,
            LaborCoveredUnitOfTime = 'Months',
            PartsCovered = 100,
            PartsCoveredDuration = 36,
            PartsCoveredUnitOfTime = 'Months',
            ExpensesCovered = 0,
            ExpensesCoveredDuration = 36,
            ExpensesCoveredUnitOfTime = 'Months',
            EffectiveStartDate = 'Purchase Date',
            IsActive = true,
            IsTransferable = true
        );
        insert wt;
        g.warrantyTermId = wt.Id;

        if (activeWarranty) {
            insert new AssetWarranty(
                AssetId = ast.Id,
                WarrantyTermId = wt.Id,
                StartDate = Date.today().addYears(-1),
                EndDate = Date.today().addYears(3)
            );
        } else {
            insert new AssetWarranty(
                AssetId = ast.Id,
                WarrantyTermId = wt.Id,
                StartDate = Date.today().addYears(-5),
                EndDate = Date.today().addYears(-1)
            );
        }
        return g;
    }

    private static Claim newWarrantyClaim(
        Id accountId,
        Id productId,
        Id insuredAssetId,
        Decimal estAmount,
        Decimal mileage,
        String dealerCode,
        String summary
    ) {
        return new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = accountId,
            ProductId = productId,
            ClaimType = 'Warranty Claim',
            Status = 'Submitted',
            Severity = 'Low',
            Summary = summary,
            FnolChannel = 'Web',
            Channel__c = 'Portal',
            EstimatedAmount = estAmount,
            MileageAtClaim__c = mileage,
            InitiationDate = Date.today(),
            InsuredAssetId = insuredAssetId,
            DealerCode__c = dealerCode
        );
    }

    @IsTest
    static void testNullClaimId_returnsMessage() {
        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = null;
        Test.startTest();
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        Test.stopTest();
        System.assertEquals(1, outs.size());
        System.assert(outs[0].message.contains('required'), outs[0].message);
    }

    @IsTest
    static void testAutoApprove_lowRisk() {
        TriageGraph g = buildGraph(false, 5000, 12000, true);
        Claim cl = newWarrantyClaim(g.accountId, g.partProductId, null, 5000, 12000, 'DLR-TRI-LOW', 'LOWRISK');
        insert cl;
        insert new ClaimItem(
            Name = 'Line 1',
            ClaimId = cl.Id,
            ProductId = g.partProductId,
            VehicleId = g.vehicleId,
            AssetId = g.assetId,
            Type__c = 'Part',
            Status__c = 'New',
            Quantity__c = 1,
            UnitPrice__c = 5000,
            EstimatedAmount__c = 5000,
            LaborHours__c = 1,
            LaborRate__c = 1000,
            FaultDate = Date.today(),
            FaultDescription__c = 'Brake wear',
            CausalPartNumber__c = 'P-BPAD',
            ReplacedPartNumber__c = 'P-BPAD'
        );

        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        Test.startTest();
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        Test.stopTest();

        System.assertEquals('Auto-Approve', outs[0].recommendation);
        System.assert(outs[0].riskScore <= 20, 'expected approve band');
        cl = [SELECT Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c FROM Claim WHERE Id = :cl.Id];
        System.assertEquals('Auto-Approve', cl.AI_Recommendation__c);
        System.assertNotEquals(null, cl.AI_Triage_Notes__c);
    }

    @IsTest
    static void testRecall_deductsScore() {
        TriageGraph g = buildGraph(true, 5000, 12000, true);
        Claim cl = newWarrantyClaim(g.accountId, g.partProductId, null, 5000, 12000, 'DLR-TRI-REC', 'RECALL');
        insert cl;
        insert new ClaimItem(
            Name = 'Line 1',
            ClaimId = cl.Id,
            ProductId = g.partProductId,
            VehicleId = g.vehicleId,
            AssetId = g.assetId,
            Type__c = 'Part',
            Status__c = 'New',
            Quantity__c = 1,
            UnitPrice__c = 5000,
            EstimatedAmount__c = 5000,
            LaborHours__c = 1,
            LaborRate__c = 1000,
            FaultDate = Date.today(),
            FaultDescription__c = 'Brake wear',
            CausalPartNumber__c = 'P-BPAD',
            ReplacedPartNumber__c = 'P-BPAD'
        );
        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assertEquals('Auto-Approve', outs[0].recommendation);
        System.assert(outs[0].factors != null && outs[0].factors.contains('recall'), outs[0].factors);
    }

    @IsTest
    static void testNeedsReview_mediumRisk() {
        TriageGraph g = buildGraph(false, 450000, 70000, true);
        Claim cl = newWarrantyClaim(g.accountId, g.partProductId, null, 450000, 70000, 'DLR-TRI-MID', 'MIDRISK');
        insert cl;
        insert new ClaimItem(
            Name = 'Line 1',
            ClaimId = cl.Id,
            ProductId = g.partProductId,
            VehicleId = g.vehicleId,
            AssetId = g.assetId,
            Type__c = 'Part',
            Status__c = 'New',
            Quantity__c = 1,
            UnitPrice__c = 1000,
            EstimatedAmount__c = 1000,
            LaborHours__c = 1,
            LaborRate__c = 1000,
            FaultDate = Date.today(),
            FaultDescription__c = 'Wear',
            CausalPartNumber__c = 'P1',
            ReplacedPartNumber__c = 'P1'
        );
        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assertEquals('Needs Review', outs[0].recommendation);
        System.assert(outs[0].riskScore > 20 && outs[0].riskScore < 80, String.valueOf(outs[0].riskScore));
    }

    @IsTest
    static void testAutoDeny_noAsset() {
        Account acct = new Account(Name = 'Delhi Electra Express', Type = 'Partner');
        insert acct;
        Product2 pProd = new Product2(
            Name = 'Regenerative Brake Controller',
            ProductCode = 'P-TRI-DENY-' + String.valueOf(Crypto.getRandomInteger()),
            IsActive = true
        );
        insert pProd;
        Claim cl = newWarrantyClaim(acct.Id, pProd.Id, null, 5000, 1000, 'DLR-TRI-DENY', 'NOASSET');
        insert cl;

        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assertEquals('Auto-Deny', outs[0].recommendation);
        System.assert(outs[0].riskScore >= 80, String.valueOf(outs[0].riskScore));
    }

    @IsTest
    static void testMileageExceeded() {
        TriageGraph g = buildGraph(false, 8000, 125000, true);
        Claim cl = newWarrantyClaim(g.accountId, g.partProductId, null, 8000, 125000, 'DLR-TRI-MIL', 'MILEAGE');
        insert cl;
        insert new ClaimItem(
            Name = 'Line 1',
            ClaimId = cl.Id,
            ProductId = g.partProductId,
            VehicleId = g.vehicleId,
            AssetId = g.assetId,
            Type__c = 'Part',
            Status__c = 'New',
            Quantity__c = 1,
            UnitPrice__c = 8000,
            EstimatedAmount__c = 8000,
            LaborHours__c = 1,
            LaborRate__c = 1000,
            FaultDate = Date.today(),
            FaultDescription__c = 'Wear',
            CausalPartNumber__c = 'P1',
            ReplacedPartNumber__c = 'P1'
        );
        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assert(outs[0].factors.contains('mileage') || outs[0].triageNotes.contains('mileage'), outs[0].triageNotes);
    }

    @IsTest
    static void testDealerVolume_anomaly() {
        TriageGraph g = buildGraph(false, 450000, 12000, true);
        List<Claim> noise = new List<Claim>();
        for (Integer i = 0; i < 11; i++) {
            noise.add(
                newWarrantyClaim(
                    g.accountId,
                    g.partProductId,
                    null,
                    100,
                    1000,
                    'DLR-VOL-' + String.valueOf(i),
                    'VOLNOISE' + String.valueOf(i)
                )
            );
        }
        insert noise;

        Claim cl = newWarrantyClaim(g.accountId, g.partProductId, null, 450000, 12000, 'DLR-TRI-VOL', 'VOLMAIN');
        insert cl;
        insert new ClaimItem(
            Name = 'Line 1',
            ClaimId = cl.Id,
            ProductId = g.partProductId,
            VehicleId = g.vehicleId,
            AssetId = g.assetId,
            Type__c = 'Part',
            Status__c = 'New',
            Quantity__c = 1,
            UnitPrice__c = 1000,
            EstimatedAmount__c = 1000,
            LaborHours__c = 1,
            LaborRate__c = 1000,
            FaultDate = Date.today(),
            FaultDescription__c = 'Wear',
            CausalPartNumber__c = 'P1',
            ReplacedPartNumber__c = 'P1'
        );

        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = cl.Id;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assert(outs[0].factors.contains('volume') || outs[0].triageNotes.contains('volume'), outs[0].triageNotes);
    }

    @IsTest
    static void testBulk_manyClaims() {
        Account acct = new Account(Name = 'Bay Area Electra Motors', Type = 'Partner');
        insert acct;
        Product2 pProd = new Product2(
            Name = 'EV Battery Module Assembly',
            ProductCode = 'P-BULK-' + String.valueOf(Crypto.getRandomInteger()),
            IsActive = true
        );
        insert pProd;
        List<Claim> claims = new List<Claim>();
        for (Integer i = 0; i < 200; i++) {
            claims.add(newWarrantyClaim(acct.Id, pProd.Id, null, 100, 1000, 'DLR-BLK', 'BULK' + String.valueOf(i)));
        }
        insert claims;

        List<WC_ClaimTriageService.Input> inputs = new List<WC_ClaimTriageService.Input>();
        for (Claim c : claims) {
            WC_ClaimTriageService.Input ir = new WC_ClaimTriageService.Input();
            ir.claimId = c.Id;
            inputs.add(ir);
        }
        Test.startTest();
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(inputs);
        Test.stopTest();
        System.assertEquals(200, outs.size());
        for (WC_ClaimTriageService.Output o : outs) {
            System.assertEquals('Auto-Deny', o.recommendation);
        }
    }

    @IsTest
    static void testInvalidClaimId_notFound() {
        Id userId = [SELECT Id FROM User WHERE IsActive = true AND Profile.Name != null LIMIT 1].Id;
        WC_ClaimTriageService.Input inRow = new WC_ClaimTriageService.Input();
        inRow.claimId = userId;
        List<WC_ClaimTriageService.Output> outs = WC_ClaimTriageService.execute(new List<WC_ClaimTriageService.Input>{ inRow });
        System.assertEquals(-1, outs[0].riskScore);
        System.assert(outs[0].message.contains('not found'), outs[0].message);
    }
}