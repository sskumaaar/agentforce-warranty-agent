@isTest
private class WC_CreateClaimTest {

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

        Product2 part = new Product2(
            Name = 'EV Brake Pad Kit',
            ProductCode = 'P-BPAD-001',
            Family = 'Brakes',
            IsActive = true
        );
        insert part;
    }

    @isTest
    static void testCreateClaim_ValidInputs() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];

        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'Regenerative brake pad showing uneven wear at 30,000 km';
        inp.currentMileage = 30000;
        inp.estimatedAmount = 2500;
        inp.channel = 'Web_Chat';
        inp.dealerAccountId = dealer.Id;

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_CreateClaim.Output out = results[0];
        Assert.isTrue(out.success);
        Assert.isNotNull(out.claimId);
        Assert.isNotNull(out.claimNumber);
        Assert.areEqual('New', out.status);
        Assert.isTrue(out.message.contains('EV Brake Pad Kit'));
    }

    @isTest
    static void testCreateClaim_VehicleNotFound() {
        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '9XXXX0000FAKE999';
        inp.partCode = 'P-BPAD-001';

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('No vehicle found'));
    }

    @isTest
    static void testCreateClaim_PartNotFound() {
        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'NONEXISTENT-999';

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('Part code not found'));
    }

    @isTest
    static void testCreateClaim_WithOptionalFields() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];
        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'Battery module not charging past 60%';
        inp.currentMileage = 45000;
        inp.diagnosticTroubleCode = 'P0300';
        inp.channel = 'Portal';
        inp.estimatedAmount = 8500;
        inp.dealerAccountId = dealer.Id;

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.isTrue(results[0].success);

        Claim created = [
            SELECT MileageAtClaim__c, DiagnosticTroubleCode__c, Channel__c
            FROM Claim
            WHERE Id = :results[0].claimId
        ];
        Assert.areEqual(45000, created.MileageAtClaim__c);
        Assert.areEqual('P0300', created.DiagnosticTroubleCode__c);
        Assert.areEqual('Portal', created.Channel__c);
    }

    @isTest
    static void testCreateClaim_Bulk() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        WarrantyTerm wt = [SELECT Id FROM WarrantyTerm LIMIT 1];

        List<Asset> assets = new List<Asset>();
        for (Integer i = 0; i < 200; i++) {
            assets.add(new Asset(
                Name = 'Bulk Claim Asset ' + i,
                AccountId = dealer.Id
            ));
        }
        insert assets;

        VehicleDefinition vd2 = [SELECT Id FROM VehicleDefinition LIMIT 1];
        List<Vehicle> vehicles = new List<Vehicle>();
        for (Integer i = 0; i < 200; i++) {
            // [v22.1] Canonical 17-char VIN: 1ELECCLMBULK (12) + 5-digit seq.
            String seq = String.valueOf(i).leftPad(5, '0');
            vehicles.add(new Vehicle(
                Name = 'Bulk Claim Vehicle ' + seq,
                VehicleIdentificationNumber = '1ELECCLMBULK' + seq,
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

        List<WC_CreateClaim.Input> inputs = new List<WC_CreateClaim.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
            String seq = String.valueOf(i).leftPad(5, '0');
            inp.vinNumber = '1ELECCLMBULK' + seq;
            inp.partCode = 'P-BPAD-001';
            inp.failureDescription = 'Brake wear issue on vehicle ' + i;
            inp.dealerAccountId = dealer.Id;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        Integer successCount = 0;
        for (WC_CreateClaim.Output out : results) {
            if (out.success) {
                successCount++;
            }
        }
        Assert.isTrue(successCount > 0, 'At least some claims should be created');
    }

    /**
     * Cross-dealer scenario: vehicle is registered to Pune (test setup), but
     * the input dealerAccountId is a DIFFERENT dealer (Mumbai). The output
     * must:
     *   - succeed (any Electra dealer can file a warranty claim on any VIN)
     *   - return crossDealer=true and originalDealerName='Pune Electra Service Center'
     *   - persist the Claim with AccountId=Mumbai (servicing dealer, NOT the
     *     vehicle's owner — fixes the long-standing bug where the claim
     *     attributed to the wrong dealer)
     *   - prefix the Summary with [Cross-dealer service · originally sold by Pune…]
     */
    @isTest
    static void testCreateClaim_crossDealerDetection() {
        Account puneOwner = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];
        Account mumbai = new Account(Name='Mumbai Cross-Dealer Test');
        insert mumbai;

        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';     // owned by Pune
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'Customer travelled, presenting at Mumbai service centre';
        inp.estimatedAmount = 5000;
        inp.dealerAccountId = mumbai.Id;        // SERVICING dealer = Mumbai
        inp.channel = 'Web_Chat';

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        WC_CreateClaim.Output out = results[0];
        Assert.isTrue(out.success, 'Cross-dealer claim must be allowed');
        Assert.areEqual(true, out.crossDealer, 'Output crossDealer flag must be true');
        Assert.areEqual('Pune Electra Service Center', out.originalDealerName,
            'originalDealerName should be the registering dealer (Pune)');

        Claim persisted = [
            SELECT AccountId, Summary
            FROM Claim
            WHERE Id = :out.claimId
        ];
        Assert.areEqual(mumbai.Id, persisted.AccountId,
            'Claim.AccountId must be the SERVICING dealer (Mumbai), not the vehicle owner (Pune)');
        Assert.isTrue(persisted.Summary.startsWith('[Cross-dealer service'),
            'Summary must be prefixed with the cross-dealer note');
        Assert.isTrue(persisted.Summary.contains('Pune Electra Service Center'),
            'Cross-dealer prefix must name the originating dealer');
    }

    /**
     * Same-dealer guard: when vehicle is owned by the same dealer that's
     * filing the claim, crossDealer must be FALSE — no false positive.
     */
    @isTest
    static void testCreateClaim_sameDealer_notCrossDealer() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];

        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'In-fleet repair';
        inp.dealerAccountId = dealer.Id;        // same as Asset.AccountId
        inp.estimatedAmount = 1500;

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.isTrue(results[0].success);
        Assert.areEqual(false, results[0].crossDealer == true,
            'Same-dealer claim must not have crossDealer=true');

        Claim persisted = [SELECT Summary FROM Claim WHERE Id = :results[0].claimId];
        Assert.isFalse(persisted.Summary.startsWith('[Cross-dealer'),
            'Same-dealer Summary must NOT have the cross-dealer prefix');
    }

    /**
     * ClaimShare side-effect: every successfully-created claim should have a
     * ClaimShare row inserted for the running user so they can see the claim
     * back in the dealer portal. Without this share, external OWD on Claim
     * (Private) makes the new record invisible to the dealer who created it.
     */
    @isTest
    static void testCreateClaim_claimShareInserted() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];

        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'ClaimShare test';
        inp.dealerAccountId = dealer.Id;

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.isTrue(results[0].success);
        Id claimId = results[0].claimId;
        // Look up ClaimShare rows for this claim — we expect at least one
        // share for the running user (Manual rowCause)
        List<ClaimShare> shares = [
            SELECT UserOrGroupId, AccessLevel, RowCause
            FROM ClaimShare
            WHERE ParentId = :claimId AND UserOrGroupId = :UserInfo.getUserId()
        ];
        Assert.isTrue(shares.size() >= 1,
            'ClaimShare row should be inserted for the running user so they can see their own claim');
    }

    @isTest
    static void testCreateClaim_VerifyClaimItemCreated() {
        Account dealer = [SELECT Id FROM Account WHERE Name = 'Pune Electra Service Center' LIMIT 1];
        Product2 part = [SELECT Id FROM Product2 WHERE ProductCode = 'P-BPAD-001' LIMIT 1];

        WC_CreateClaim.Input inp = new WC_CreateClaim.Input();
        inp.vinNumber = '1ELEC2025BOLT0001';
        inp.partCode = 'P-BPAD-001';
        inp.failureDescription = 'Brake squealing at low speed';
        inp.estimatedAmount = 3200;
        inp.dealerAccountId = dealer.Id;
        inp.channel = 'Phone';

        Test.startTest();
        List<WC_CreateClaim.Output> results = WC_CreateClaim.execute(
            new List<WC_CreateClaim.Input>{ inp }
        );
        Test.stopTest();

        Assert.isTrue(results[0].success);

        List<ClaimItem> items = [
            SELECT ClaimId, ProductId, Description
            FROM ClaimItem
            WHERE ClaimId = :results[0].claimId
        ];
        Assert.areEqual(1, items.size());
        Assert.areEqual(part.Id, items[0].ProductId);
        Assert.areEqual('Brake squealing at low speed', items[0].Description);
    }
}