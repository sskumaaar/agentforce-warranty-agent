@IsTest
private class WC_DealerInsightsTest {

    @IsTest
    static void capabilitiesActionReturnsChips() {
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'capabilities';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        WC_DealerInsights.Output o = out[0];
        System.assertEquals(true, o.success, 'capabilities must succeed: ' + o.message);
        System.assertEquals('capabilities', o.type);
        System.assertNotEquals(null, o.intro, 'intro must populate');
        System.assertNotEquals(null, o.chips, 'chips must populate');
        System.assert(o.chips.size() >= 6, 'expected at least 6 chips, got ' + o.chips.size());
        for (WC_DealerInsights.CapabilityChip c : o.chips) {
            System.assertNotEquals(null, c.icon,    'each chip needs an icon');
            System.assertNotEquals(null, c.label,   'each chip needs a label');
            System.assertNotEquals(null, c.triggerPhrase, 'each chip needs a trigger phrase');
        }
        // Pre-serialized JSON envelope must contain the type + chips array.
        System.assert(o.formattedJson != null && o.formattedJson.length() > 50,
            'formattedJson must be populated and substantial');
        System.assert(o.formattedJson.contains('"type":"capabilities"'),
            'envelope must declare type: ' + o.formattedJson);
        System.assert(o.formattedJson.contains('"chips"'),
            'envelope must contain chips array');
    }

    @IsTest
    static void capabilitiesIsCaseInsensitive() {
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'CAPABILITIES';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(true, out[0].success, 'uppercase action must still match');
        System.assertEquals('capabilities', out[0].type);
    }

    @IsTest
    static void unknownActionStillReturnsSuccessfullyWithError() {
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'not-a-real-action';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size(), 'must return exactly one Output');
        // Bad action returns success=false but still produces a structured envelope
        // — the bot needs SOMETHING to echo so the user sees a clean error.
        System.assertEquals(false, out[0].success);
        System.assertNotEquals(null, out[0].formattedJson);
        System.assert(out[0].message != null && out[0].message.contains('Unknown action'),
            'message must surface unknown-action diagnostics');
    }

    @IsTest
    static void greetingActionReturnsChipsAndIntro() {
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'greeting';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(true, out[0].success);
        System.assertEquals('greeting', out[0].type);
        System.assertNotEquals(null, out[0].intro, 'intro must populate');
        System.assert(out[0].intro.toLowerCase().contains('hi'),
            'greeting intro should start with hi/hello');
        System.assertNotEquals(null, out[0].chips);
        System.assert(out[0].chips.size() >= 3, 'expected suggested chips');
        System.assert(out[0].formattedJson.contains('"type":"greeting"'),
            'envelope must declare type: ' + out[0].formattedJson);
    }

    @IsTest
    static void offTopicActionReturnsRedirectChips() {
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'off-topic';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(true, out[0].success);
        System.assertEquals('off-topic', out[0].type);
        System.assertNotEquals(null, out[0].intro);
        System.assert(out[0].intro.toLowerCase().contains('electra')
                   || out[0].intro.toLowerCase().contains('warranty'),
            'off-topic redirect should mention the domain we DO cover');
        System.assertNotEquals(null, out[0].chips);
        System.assert(out[0].chips.size() >= 2, 'expected at least 2 redirect chips');
    }

    @IsTest
    static void warrantyInfoActionReturnsFaqWithoutVin() {
        // [v22.9] No-VIN warranty FAQ — closes the user-reported bug where
        // "what does the warranty cover?" was punted to Lead creation.
        WC_DealerInsights.Input req = new WC_DealerInsights.Input();
        req.action = 'warranty-info';

        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(
            new List<WC_DealerInsights.Input>{ req });
        Test.stopTest();

        System.assertEquals(true, out[0].success);
        System.assertEquals('warranty-info', out[0].type);
        System.assertNotEquals(null, out[0].intro);
        System.assertNotEquals(null, out[0].items, 'FAQ items must populate');
        System.assert(out[0].items.size() >= 4, 'expected at least 4 coverage bullets');
        System.assertNotEquals(null, out[0].footer);
        System.assert(out[0].formattedJson.contains('"type":"warranty-info"'));
        System.assert(out[0].formattedJson.contains('"items"'));
    }

    @IsTest
    static void emptyInputListReturnsErrorOutput() {
        Test.startTest();
        List<WC_DealerInsights.Output> out = WC_DealerInsights.execute(new List<WC_DealerInsights.Input>());
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].success);
    }
}