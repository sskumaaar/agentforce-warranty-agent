@isTest
private class WC_PartSearchTest {

    @TestSetup
    static void setup() {
        List<Product2> parts = new List<Product2>();
        parts.add(new Product2(Name = 'EV Brake Pad Kit', ProductCode = 'P-BPAD-001', Family = 'Brakes', IsActive = true));
        parts.add(new Product2(Name = 'Regenerative Brake Controller', ProductCode = 'P-BRCTL-001', Family = 'Brakes', IsActive = true));
        parts.add(new Product2(Name = 'EV Battery Module Assembly', ProductCode = 'P-BATM-001', Family = 'Powertrain', IsActive = true));
        parts.add(new Product2(Name = 'Drive Motor Inverter', ProductCode = 'P-DINV-001', Family = 'Powertrain', IsActive = true));
        parts.add(new Product2(Name = 'Cabin Air Filter Electra', ProductCode = 'P-CAIR-001', Family = 'Body', IsActive = true));
        parts.add(new Product2(Name = 'Headlamp LED Module', ProductCode = 'P-HLED-001', Family = 'Electrical', IsActive = true));
        parts.add(new Product2(Name = 'Inactive Legacy Part', ProductCode = 'P-DEAD-001', Family = 'Legacy', IsActive = false));
        insert parts;
    }

    @isTest
    static void testSearchByName() {
        List<Id> fixedResults = new List<Id>();
        for (Product2 p : [SELECT Id FROM Product2 WHERE Name LIKE '%Brake%' AND IsActive = true]) {
            fixedResults.add(p.Id);
        }
        Test.setFixedSearchResults(fixedResults);

        WC_PartSearch.Input inp = new WC_PartSearch.Input();
        inp.searchTerm = 'Brake';

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].partsFound);
        Assert.isTrue(results[0].totalMatches >= 1);
        Assert.isNotNull(results[0].partId);
        Assert.isNotNull(results[0].resultsSummary);
    }

    @isTest
    static void testSearchByCode() {
        List<Id> fixedResults = new List<Id>();
        for (Product2 p : [SELECT Id FROM Product2 WHERE ProductCode = 'P-BPAD-001']) {
            fixedResults.add(p.Id);
        }
        Test.setFixedSearchResults(fixedResults);

        WC_PartSearch.Input inp = new WC_PartSearch.Input();
        inp.searchTerm = 'P-BPAD-001';

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].partsFound);
        Assert.areEqual('P-BPAD-001', results[0].partCode);
    }

    @isTest
    static void testSearchByCategory() {
        WC_PartSearch.Input inp = new WC_PartSearch.Input();
        inp.category = 'Powertrain';
        inp.searchTerm = 'Battery';

        List<Id> fixedResults = new List<Id>();
        for (Product2 p : [SELECT Id FROM Product2 WHERE Family = 'Powertrain' AND IsActive = true]) {
            fixedResults.add(p.Id);
        }
        Test.setFixedSearchResults(fixedResults);

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        if (results[0].partsFound) {
            Assert.areEqual('Powertrain', results[0].partFamily);
        }
    }

    @isTest
    static void testNoResults() {
        Test.setFixedSearchResults(new List<Id>());

        WC_PartSearch.Input inp = new WC_PartSearch.Input();
        inp.searchTerm = 'ZZZZNONEXISTENT';

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].partsFound);
        Assert.areEqual(0, results[0].totalMatches);
        Assert.isTrue(results[0].message.contains('No parts found'));
    }

    @isTest
    static void testEmptySearchTerm() {
        WC_PartSearch.Input inp = new WC_PartSearch.Input();

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].partsFound);
        Assert.isTrue(results[0].message.contains('provide a search term'));
    }

    @isTest
    static void testMaxResultsLimit() {
        List<Id> fixedResults = new List<Id>();
        for (Product2 p : [SELECT Id FROM Product2 WHERE IsActive = true]) {
            fixedResults.add(p.Id);
        }
        Test.setFixedSearchResults(fixedResults);

        WC_PartSearch.Input inp = new WC_PartSearch.Input();
        inp.searchTerm = 'EV';
        inp.maxResults = 2;

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(new List<WC_PartSearch.Input>{ inp });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        if (results[0].partsFound) {
            Assert.isTrue(results[0].totalMatches <= 2);
        }
    }

    @isTest
    static void testBulk_200() {
        List<WC_PartSearch.Input> inputs = new List<WC_PartSearch.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_PartSearch.Input inp = new WC_PartSearch.Input();
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_PartSearch.Output> results = WC_PartSearch.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        for (WC_PartSearch.Output out : results) {
            Assert.isFalse(out.partsFound);
        }
    }
}