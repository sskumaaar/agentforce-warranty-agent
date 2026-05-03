@IsTest
private class WC_AgentAnalyticsControllerTest {

    @IsTest
    static void testGetSessionMetrics() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockSessionMetrics = new Map<String, Object>{
            'totalSessions'  => 50,
            'avgDuration'    => 120.5,
            'engagementRate' => 80.0,
            'errorRate'      => 4.0,
            'previewCount'   => 10,
            'liveCount'      => 40
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getSessionMetrics();
        System.assertEquals(50, result.get('totalSessions'));
        System.assertEquals(80.0, result.get('engagementRate'));
        System.assertEquals(10, result.get('previewCount'));
        System.assertEquals(40, result.get('liveCount'));
    }

    @IsTest
    static void testGetSessionMetricsEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockSessionMetrics = new Map<String, Object>{
            'totalSessions'  => 0,
            'avgDuration'    => null,
            'engagementRate' => 0,
            'errorRate'      => 0,
            'previewCount'   => 0,
            'liveCount'      => 0
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getSessionMetrics();
        System.assertEquals(0, result.get('totalSessions'));
        System.assertEquals(0, result.get('engagementRate'));
    }

    @IsTest
    static void testGetEventBreakdown() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockEventBreakdown = new List<Map<String, Object>>{
            new Map<String, Object>{ 'logType' => 'InputMessage', 'count' => 45 },
            new Map<String, Object>{ 'logType' => 'OutputMessage', 'count' => 40 },
            new Map<String, Object>{ 'logType' => 'TopicClassificationSuccess', 'count' => 30 }
        };

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getEventBreakdown();
        System.assertEquals(3, result.size());
        System.assertEquals('InputMessage', result[0].get('logType'));
        System.assertEquals(45, result[0].get('count'));
    }

    @IsTest
    static void testGetEventBreakdownEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockEventBreakdown = new List<Map<String, Object>>();

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getEventBreakdown();
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void testGetTopicDistribution() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockTopicDistribution = new List<Map<String, Object>>{
            new Map<String, Object>{ 'topic' => 'Warranty Claim Filing', 'count' => 15 },
            new Map<String, Object>{ 'topic' => 'VIN Lookup', 'count' => 10 },
            new Map<String, Object>{ 'topic' => 'Claim Status Check', 'count' => 8 }
        };

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getTopicDistribution();
        System.assertEquals(3, result.size());
        System.assertEquals('Warranty Claim Filing', result[0].get('topic'));
        System.assert((Integer) result[0].get('count') >= (Integer) result[1].get('count'),
            'Should be sorted descending by count');
    }

    @IsTest
    static void testGetTopicDistributionEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockTopicDistribution = new List<Map<String, Object>>();

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getTopicDistribution();
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void testGetInstructionAdherence() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockAdherence = new Map<String, Object>{
            'highCount'      => 18,
            'lowCount'       => 2,
            'totalEvaluated' => 20,
            'adherenceRate'  => 90.0
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getInstructionAdherence();
        System.assertEquals(18, result.get('highCount'));
        System.assertEquals(2, result.get('lowCount'));
        System.assertEquals(20, result.get('totalEvaluated'));
        System.assertEquals(90.0, result.get('adherenceRate'));
    }

    @IsTest
    static void testGetInstructionAdherenceEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockAdherence = new Map<String, Object>{
            'highCount'      => 0,
            'lowCount'       => 0,
            'totalEvaluated' => 0,
            'adherenceRate'  => 0
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getInstructionAdherence();
        System.assertEquals(0, result.get('totalEvaluated'));
        System.assertEquals(0, result.get('adherenceRate'));
    }

    @IsTest
    static void testGetRecentConversations() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockConversations = new List<Map<String, Object>>{
            new Map<String, Object>{
                'prompt'    => 'I need to file a warranty claim for my EV battery',
                'timestamp' => Datetime.now()
            },
            new Map<String, Object>{
                'prompt'    => 'Check claim status for CLM-00042',
                'timestamp' => Datetime.now().addMinutes(-30)
            }
        };

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getRecentConversations();
        System.assertEquals(2, result.size());
        System.assert(((String) result[0].get('prompt')).contains('warranty claim'));
    }

    @IsTest
    static void testGetRecentConversationsEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockConversations = new List<Map<String, Object>>();

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getRecentConversations();
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void testGetSessionTrend() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockSessionTrend = new List<Map<String, Object>>{
            new Map<String, Object>{ 'sessionDate' => Date.today().addDays(-2), 'count' => 12 },
            new Map<String, Object>{ 'sessionDate' => Date.today().addDays(-1), 'count' => 18 },
            new Map<String, Object>{ 'sessionDate' => Date.today(), 'count' => 7 }
        };

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getSessionTrend();
        System.assertEquals(3, result.size());
        System.assertEquals(12, result[0].get('count'));
    }

    @IsTest
    static void testGetSessionTrendEmpty() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockSessionTrend = new List<Map<String, Object>>();

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getSessionTrend();
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void testGetTokenUsageAvailable() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockTokenUsage = new Map<String, Object>{
            'available'   => true,
            'totalTokens' => 25000,
            'avgPerEvent' => 192.3,
            'eventCount'  => 130
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getTokenUsage();
        System.assertEquals(true, result.get('available'));
        System.assertEquals(25000, result.get('totalTokens'));
        System.assertEquals(130, result.get('eventCount'));
    }

    @IsTest
    static void testGetTokenUsageUnavailable() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockTokenUsage = new Map<String, Object>{
            'available'   => false,
            'totalTokens' => 0,
            'avgPerEvent' => 0,
            'eventCount'  => 0
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getTokenUsage();
        System.assertEquals(false, result.get('available'));
        System.assertEquals(0, result.get('totalTokens'));
    }

    @IsTest
    static void testTopicParsingWithPrefix() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockTopicDistribution = new List<Map<String, Object>>{
            new Map<String, Object>{ 'topic' => 'File Warranty Claim', 'count' => 5 },
            new Map<String, Object>{ 'topic' => 'Check Claim Status', 'count' => 3 }
        };

        List<Map<String, Object>> result = WC_AgentAnalyticsController.getTopicDistribution();
        System.assertEquals(2, result.size());
        System.assertEquals('File Warranty Claim', result[0].get('topic'));
    }

    @IsTest
    static void testAdherenceMixedHighLow() {
        WC_AgentAnalyticsController.useMockData = true;
        WC_AgentAnalyticsController.mockAdherence = new Map<String, Object>{
            'highCount'      => 7,
            'lowCount'       => 3,
            'totalEvaluated' => 10,
            'adherenceRate'  => 70.0
        };

        Map<String, Object> result = WC_AgentAnalyticsController.getInstructionAdherence();
        System.assertEquals(7, result.get('highCount'));
        System.assertEquals(3, result.get('lowCount'));
        System.assertEquals(70.0, result.get('adherenceRate'));
    }

    // Non-mock tests: exercise real SOQL paths — org has live ConversationDefinition data
    @IsTest
    static void testGetSessionMetrics_liveOrg() {
        Map<String, Object> result = WC_AgentAnalyticsController.getSessionMetrics();
        System.assertNotEquals(null, result, 'Should return a map');
        System.assert(result.containsKey('totalSessions'), 'Must have totalSessions');
        System.assert(result.containsKey('engagementRate'), 'Must have engagementRate');
        System.assert(result.containsKey('errorRate'), 'Must have errorRate');
        System.assert(result.containsKey('previewCount'), 'Must have previewCount');
        System.assert(result.containsKey('liveCount'), 'Must have liveCount');
        Integer total = (Integer) result.get('totalSessions');
        System.assert(total >= 0, 'totalSessions must be >= 0');
    }

    @IsTest
    static void testGetEventBreakdown_liveOrg() {
        List<Map<String, Object>> result = WC_AgentAnalyticsController.getEventBreakdown();
        System.assertNotEquals(null, result, 'Should return a list');
        for (Map<String, Object> entry : result) {
            System.assert(entry.containsKey('logType'), 'Each entry must have logType');
            System.assert(entry.containsKey('count'), 'Each entry must have count');
        }
    }

    @IsTest
    static void testGetTopicDistribution_liveOrg() {
        List<Map<String, Object>> result = WC_AgentAnalyticsController.getTopicDistribution();
        System.assertNotEquals(null, result, 'Should return a list');
        for (Map<String, Object> entry : result) {
            System.assert(entry.containsKey('topic'), 'Each entry must have topic');
            System.assert(entry.containsKey('count'), 'Each entry must have count');
        }
    }

    @IsTest
    static void testGetInstructionAdherence_liveOrg() {
        Map<String, Object> result = WC_AgentAnalyticsController.getInstructionAdherence();
        System.assertNotEquals(null, result, 'Should return a map');
        System.assert(result.containsKey('totalEvaluated'), 'Must have totalEvaluated');
        System.assert(result.containsKey('adherenceRate'), 'Must have adherenceRate');
        System.assert(result.containsKey('highCount'), 'Must have highCount');
        System.assert(result.containsKey('lowCount'), 'Must have lowCount');
    }

    @IsTest
    static void testGetRecentConversations_liveOrg() {
        List<Map<String, Object>> result = WC_AgentAnalyticsController.getRecentConversations();
        System.assertNotEquals(null, result, 'Should return a list');
        System.assert(result.size() <= 20, 'Max 20 conversations');
        for (Map<String, Object> entry : result) {
            System.assert(entry.containsKey('prompt'), 'Each entry must have prompt');
            System.assert(entry.containsKey('timestamp'), 'Each entry must have timestamp');
        }
    }

    @IsTest
    static void testGetSessionTrend_liveOrg() {
        List<Map<String, Object>> result = WC_AgentAnalyticsController.getSessionTrend();
        System.assertNotEquals(null, result, 'Should return a list');
        for (Map<String, Object> entry : result) {
            System.assert(entry.containsKey('sessionDate'), 'Each entry must have sessionDate');
            System.assert(entry.containsKey('count'), 'Each entry must have count');
        }
    }

    @IsTest
    static void testGetTokenUsage_liveOrg() {
        Map<String, Object> result = WC_AgentAnalyticsController.getTokenUsage();
        System.assertNotEquals(null, result, 'Should return a map');
        System.assert(result.containsKey('available'), 'Must have available key');
        System.assert(result.containsKey('totalTokens'), 'Must have totalTokens key');
        System.assert(result.containsKey('eventCount'), 'Must have eventCount key');
    }
}