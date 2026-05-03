@IsTest
private class WC_RiskBreakdownDeriverTest {

    @TestSetup
    static void makeData() {
        Account dealer = new Account(Name = 'Pune Electra Service Center');
        insert dealer;

        Datetime now = Datetime.now();
        List<Claim> claims = new List<Claim>{
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Under Review',
                Risk_Score__c = 78,
                EstimatedAmount = 65000,
                Channel__c = 'Portal',
                MileageAtClaim__c = 67200,
                DiagnosticTroubleCode__c = 'P0420',
                FailureDescription__c = 'Battery thermal runaway during fast charging at Pune service center',
                RepairOrderNumber__c = 'RO-2026-0042',
                InitiationDate = now.addDays(-2),
                Summary = 'Battery module degradation under warranty review'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'New',
                Risk_Score__c = 22,
                EstimatedAmount = 4500,
                Channel__c = 'Portal',
                InitiationDate = now,
                Summary = 'Standard service under warranty'
            )
        };
        insert claims;
    }

    @IsTest
    static void testDeriveJsonForFullDataClaim() {
        Claim c = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c,
                          FailureDescription__c, RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                   FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 78 LIMIT 1];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(c);
        Test.stopTest();

        System.assertNotEquals(null, breakdownStr, 'Deriver should return a JSON string');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        System.assertEquals(WC_RiskBreakdownDeriver.METHODOLOGY, (String) parsed.get('version'));
        List<Object> factors = (List<Object>) parsed.get('factors');
        System.assert(factors.size() >= 4, 'Should produce at least 4 factors for fully-populated claim');

        Decimal totalContribution = (Decimal) parsed.get('totalContribution');
        Decimal finalScore = (Decimal) parsed.get('finalScore');
        Decimal residual = (Decimal) parsed.get('residual');
        System.assertEquals(c.Risk_Score__c, finalScore, 'finalScore should equal Risk_Score__c');
        System.assertEquals(finalScore - totalContribution, residual, 'residual = finalScore - totalContribution');
    }

    @IsTest
    static void testDeriveJsonForSparseClaim() {
        Claim c = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c,
                          FailureDescription__c, RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                   FROM Claim WHERE Status = 'New' AND Risk_Score__c = 22 LIMIT 1];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(c);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        System.assert(factors.size() >= 2, 'Sparse claims still produce at least 2 factors');
    }

    @IsTest
    static void testComputeConfidence() {
        Claim full = [SELECT Id, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c,
                             RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                      FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 78 LIMIT 1];
        Claim sparse = [SELECT Id, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c,
                               RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                        FROM Claim WHERE Status = 'New' AND Risk_Score__c = 22 LIMIT 1];

        Decimal fullConf = WC_RiskBreakdownDeriver.computeConfidence(full);
        Decimal sparseConf = WC_RiskBreakdownDeriver.computeConfidence(sparse);

        System.assert(fullConf > sparseConf, 'Full data claim should have higher confidence than sparse');
        System.assert(fullConf <= 100, 'Confidence cannot exceed 100');
    }

    @IsTest
    static void testBackfill() {
        Test.startTest();
        WC_RiskBreakdownDeriver.backfillBreakdownsForOpenClaims(50);
        Test.stopTest();

        List<Claim> updated = [SELECT Id, Risk_Score_Breakdown__c, Risk_Score_Methodology__c,
                                      Risk_Score_Calculated_At__c, Risk_Score_Confidence__c
                               FROM Claim WHERE Risk_Score__c != null];
        System.assertEquals(2, updated.size(), 'Both test claims have scores and should be backfilled');
        for (Claim c : updated) {
            System.assertNotEquals(null, c.Risk_Score_Breakdown__c, 'Breakdown should be populated');
            System.assertEquals(WC_RiskBreakdownDeriver.METHODOLOGY, c.Risk_Score_Methodology__c);
            System.assertNotEquals(null, c.Risk_Score_Calculated_At__c);
            System.assertNotEquals(null, c.Risk_Score_Confidence__c);
        }
    }

    @IsTest
    static void testForceRebuildOverwrites() {
        Claim c = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 78 LIMIT 1];
        update new Claim(
            Id = c.Id,
            Risk_Score_Breakdown__c = '{"version":"old"}',
            Risk_Score_Methodology__c = 'old_v0.1'
        );

        Test.startTest();
        WC_RiskBreakdownDeriver.backfillBreakdownsForOpenClaims(50, true);
        Test.stopTest();

        Claim refreshed = [SELECT Risk_Score_Breakdown__c, Risk_Score_Methodology__c FROM Claim WHERE Id = :c.Id];
        System.assertEquals(WC_RiskBreakdownDeriver.METHODOLOGY, refreshed.Risk_Score_Methodology__c,
            'Force rebuild should overwrite old methodology with current one');
        System.assert(!refreshed.Risk_Score_Breakdown__c.contains('"version":"old"'),
            'Old breakdown content should be replaced');
    }

    @IsTest
    static void testRoundMileageFraudFactorFiresAtThousands() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        Claim suspicious = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id,
            Status = 'New',
            Risk_Score__c = 60,
            EstimatedAmount = 25000,
            MileageAtClaim__c = 50000,
            InitiationDate = Datetime.now()
        );
        insert suspicious;
        Claim c = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c,
                          FailureDescription__c, RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                   FROM Claim WHERE Id = :suspicious.Id];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(c);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        Boolean foundRoundFactor = false;
        for (Object o : factors) {
            Map<String, Object> f = (Map<String, Object>) o;
            if (((String) f.get('name')) == 'Round-Number Mileage') {
                foundRoundFactor = true;
                System.assertEquals('warning', (String) f.get('verdict'),
                    'Mileage at exact thousand boundary should produce a warning verdict');
                System.assert(((Decimal) f.get('contribution')) >= 5,
                    'Round-thousands contribution should be at least 5');
            }
        }
        System.assert(foundRoundFactor, 'Round-Number Mileage factor should appear when miles % 1000 == 0');
    }

    @IsTest
    static void testRoundMileageFactorSkippedForNonRoundValues() {
        Claim c = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c, DiagnosticTroubleCode__c,
                          FailureDescription__c, RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate
                   FROM Claim WHERE MileageAtClaim__c = 67200 LIMIT 1];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(c);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        for (Object o : factors) {
            Map<String, Object> f = (Map<String, Object>) o;
            if (((String) f.get('name')) == 'Round-Number Mileage') {
                System.assertEquals('neutral', (String) f.get('verdict'),
                    '67200 ends in 100s but not 1000s — should be neutral, not warning');
            }
        }
    }

    @IsTest
    static void testComebackFactorFiresWith1Prior() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        // 1 prior + 1 current = comeback warning.
        Claim prior = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'Approved',
            Vehicle_VIN__c = '1ELECCOMEBACK0001', ClaimReason = 'Battery Degradation',
            EstimatedAmount = 12000, InitiationDate = Datetime.now().addDays(-10)
        );
        Claim current = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'New', Risk_Score__c = 50,
            Vehicle_VIN__c = '1ELECCOMEBACK0001', ClaimReason = 'Battery Degradation',
            EstimatedAmount = 12000, InitiationDate = Datetime.now()
        );
        insert new List<Claim>{ prior, current };
        Claim refreshed = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c,
                                   DiagnosticTroubleCode__c, FailureDescription__c,
                                   RepairOrderNumber__c, EstimatedAmount, Channel__c,
                                   InitiationDate, Vehicle_VIN__c, ClaimReason
                            FROM Claim WHERE Id = :current.Id];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(refreshed);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        Boolean found = false;
        for (Object o : factors) {
            Map<String, Object> f = (Map<String, Object>) o;
            if ('Repeat Repair / Comeback' == (String) f.get('name')) {
                found = true;
                System.assertEquals('warning', (String) f.get('verdict'),
                    '1 prior should produce warning verdict, not fail');
                System.assert(((Decimal) f.get('contribution')) >= 10,
                    'Single-comeback contribution should be at least 10');
            }
        }
        System.assert(found, 'Repeat Repair / Comeback factor must surface for 1 prior claim');
    }

    @IsTest
    static void testComebackFactorFlagsMultipleComebacks() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        // 3 priors + 1 current = multi-comeback fail.
        List<Claim> claims = new List<Claim>();
        for (Integer i = 0; i < 3; i++) {
            claims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id, Status = 'Approved',
                Vehicle_VIN__c = '1ELECMULTICOM0001', ClaimReason = 'Brakes',
                EstimatedAmount = 8000, InitiationDate = Datetime.now().addDays(-i - 1)
            ));
        }
        Claim current = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'New', Risk_Score__c = 60,
            Vehicle_VIN__c = '1ELECMULTICOM0001', ClaimReason = 'Brakes',
            EstimatedAmount = 8000, InitiationDate = Datetime.now()
        );
        claims.add(current);
        insert claims;

        Claim refreshed = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c,
                                   DiagnosticTroubleCode__c, FailureDescription__c,
                                   RepairOrderNumber__c, EstimatedAmount, Channel__c,
                                   InitiationDate, Vehicle_VIN__c, ClaimReason
                            FROM Claim WHERE Id = :current.Id];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(refreshed);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        Boolean foundFail = false;
        for (Object o : factors) {
            Map<String, Object> f = (Map<String, Object>) o;
            if ('Repeat Repair / Comeback' == (String) f.get('name')) {
                foundFail = ('fail' == (String) f.get('verdict'));
                System.assert(((Decimal) f.get('contribution')) >= 18,
                    'Multi-comeback contribution should be at least 18');
            }
        }
        System.assert(foundFail, 'Multi-comeback (≥2 priors) must produce fail verdict');
    }

    @IsTest
    static void testNoComebackFactorWhenDifferentReason() {
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        Claim sameVinDifferentReason = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'Approved',
            Vehicle_VIN__c = '1ELECDIFFREASON01', ClaimReason = 'Software',
            EstimatedAmount = 5000, InitiationDate = Datetime.now().addDays(-5)
        );
        Claim current = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = dealer.Id, Status = 'New', Risk_Score__c = 30,
            Vehicle_VIN__c = '1ELECDIFFREASON01', ClaimReason = 'Brakes',
            EstimatedAmount = 8000, InitiationDate = Datetime.now()
        );
        insert new List<Claim>{ sameVinDifferentReason, current };

        Claim refreshed = [SELECT Id, Name, Risk_Score__c, Severity, MileageAtClaim__c,
                                   DiagnosticTroubleCode__c, FailureDescription__c,
                                   RepairOrderNumber__c, EstimatedAmount, Channel__c,
                                   InitiationDate, Vehicle_VIN__c, ClaimReason
                            FROM Claim WHERE Id = :current.Id];

        Test.startTest();
        String breakdownStr = WC_RiskBreakdownDeriver.deriveJson(refreshed);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(breakdownStr);
        List<Object> factors = (List<Object>) parsed.get('factors');
        for (Object o : factors) {
            Map<String, Object> f = (Map<String, Object>) o;
            System.assertNotEquals('Repeat Repair / Comeback', (String) f.get('name'),
                'Different ClaimReason should NOT trigger comeback factor');
        }
    }

    @IsTest
    static void testBulkBackfillUsesAggregateSoqlNotN1() {
        // Insert 6 same-VIN+reason claims with Risk_Score__c set so backfill picks them up.
        Account dealer = [SELECT Id FROM Account LIMIT 1];
        List<Claim> claims = new List<Claim>();
        for (Integer i = 0; i < 6; i++) {
            claims.add(new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id, Status = 'New', Risk_Score__c = 40,
                Vehicle_VIN__c = '1ELECBULKBACK0001', ClaimReason = 'Powertrain',
                EstimatedAmount = 10000, InitiationDate = Datetime.now().addDays(-i)
            ));
        }
        insert claims;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        WC_RiskBreakdownDeriver.backfillBreakdownsForOpenClaims(50, true);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        Integer delta = queriesAfter - queriesBefore;
        System.assert(delta < 25,
            'Bulk backfill must NOT N+1: expected < 25 queries, got ' + delta);
    }

    @IsTest
    static void testMalformedJsonFallsThroughToLazyDerive() {
        Claim c = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 78 LIMIT 1];
        update new Claim(Id = c.Id, Risk_Score_Breakdown__c = '{not valid json');

        Test.startTest();
        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail, 'Detail wrapper should still return');
        System.assertNotEquals(null, detail.riskBreakdown,
            'After malformed JSON parse fails, lazy derive should produce a fresh breakdown');
        System.assertEquals(WC_RiskBreakdownDeriver.METHODOLOGY, detail.riskBreakdownMethodology);
    }
}