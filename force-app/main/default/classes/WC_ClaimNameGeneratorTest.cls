@isTest
private class WC_ClaimNameGeneratorTest {

    @isTest
    static void next_emptyOrg_startsAtOne() {
        WC_ClaimNameGenerator.reset();
        Test.startTest();
        String n1 = WC_ClaimNameGenerator.next();
        String n2 = WC_ClaimNameGenerator.next();
        Test.stopTest();
        System.assertEquals('WC-000001', n1, 'First name on empty org should be WC-000001');
        System.assertEquals('WC-000002', n2, 'Second name should increment');
    }

    @isTest
    static void next_withSeedClaim_continuesFromMax() {
        Account dealer = new Account(Name = 'Test Dealer for Generator');
        insert dealer;
        Claim seed = new Claim(
            Name = 'WC-000086',
            AccountId = dealer.Id,
            Status = 'New',
            InitiationDate = Date.today()
        );
        insert seed;

        WC_ClaimNameGenerator.reset();
        Test.startTest();
        String next = WC_ClaimNameGenerator.next();
        Test.stopTest();
        System.assertEquals('WC-000087', next, 'Should continue from max+1');
    }

    @isTest
    static void next_ignoresNonConformingNames() {
        Account dealer = new Account(Name = 'Test Dealer for Generator NC');
        insert dealer;
        insert new List<Claim>{
            new Claim(Name = 'CLM-12345678-4729', AccountId = dealer.Id, Status = 'New', InitiationDate = Date.today()),
            new Claim(Name = 'P12-AUTO-001', AccountId = dealer.Id, Status = 'New', InitiationDate = Date.today()),
            new Claim(Name = 'WC-TEST-SEED-001', AccountId = dealer.Id, Status = 'New', InitiationDate = Date.today())
        };

        WC_ClaimNameGenerator.reset();
        Test.startTest();
        String next = WC_ClaimNameGenerator.next();
        Test.stopTest();
        System.assertEquals('WC-000001', next, 'Non-conforming names must not influence sequence');
    }

    @isTest
    static void nextBatch_returnsRequestedCount() {
        WC_ClaimNameGenerator.reset();
        Test.startTest();
        List<String> names = WC_ClaimNameGenerator.nextBatch(5);
        Test.stopTest();
        System.assertEquals(5, names.size());
        System.assertEquals('WC-000001', names[0]);
        System.assertEquals('WC-000005', names[4]);
    }

    @isTest
    static void nextBatch_handlesNullAndZero() {
        System.assertEquals(0, WC_ClaimNameGenerator.nextBatch(null).size());
        System.assertEquals(0, WC_ClaimNameGenerator.nextBatch(0).size());
        System.assertEquals(0, WC_ClaimNameGenerator.nextBatch(-3).size());
    }

    @isTest
    static void reset_forcesRequery() {
        WC_ClaimNameGenerator.reset();
        WC_ClaimNameGenerator.next();
        System.assertNotEquals(-1, WC_ClaimNameGenerator.cachedMax, 'Cache should be primed after first call');
        WC_ClaimNameGenerator.reset();
        System.assertEquals(-1, WC_ClaimNameGenerator.cachedMax, 'Reset should clear cache');
    }
}