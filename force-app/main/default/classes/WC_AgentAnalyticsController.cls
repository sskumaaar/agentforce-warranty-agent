public with sharing class WC_AgentAnalyticsController {

    @TestVisible private static Boolean useMockData = false;
    @TestVisible private static Map<String, Object> mockSessionMetrics;
    @TestVisible private static List<Map<String, Object>> mockEventBreakdown;
    @TestVisible private static List<Map<String, Object>> mockTopicDistribution;
    @TestVisible private static Map<String, Object> mockAdherence;
    @TestVisible private static List<Map<String, Object>> mockConversations;
    @TestVisible private static List<Map<String, Object>> mockSessionTrend;
    @TestVisible private static Map<String, Object> mockTokenUsage;

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSessionMetrics() {
        if (Test.isRunningTest() && useMockData) { return mockSessionMetrics; }

        AggregateResult[] baseAgg = [
            SELECT COUNT(Id) total, AVG(SessionDuration) avgDur
            FROM ConversationDefinitionSession
        ];
        Integer totalSessions = (Integer) baseAgg[0].get('total');
        Decimal avgDuration = (Decimal) baseAgg[0].get('avgDur');

        Integer errorCount = 0;
        Integer engagedCount = 0;
        Integer previewCount = 0;
        for (ConversationDefinitionSession s : [
            SELECT HasErrorLogs, WasSessionEngaged, Mode FROM ConversationDefinitionSession
        ]) {
            if (s.HasErrorLogs == true) errorCount++;
            if (s.WasSessionEngaged == true) engagedCount++;
            if (s.Mode == 'Preview') previewCount++;
        }

        Decimal engagementRate = totalSessions > 0
            ? ((Decimal) engagedCount / totalSessions * 100).setScale(1)
            : 0;
        Decimal errorRate = totalSessions > 0
            ? ((Decimal) errorCount / totalSessions * 100).setScale(1)
            : 0;

        return new Map<String, Object>{
            'totalSessions'  => totalSessions,
            'avgDuration'    => avgDuration,
            'engagementRate' => engagementRate,
            'errorRate'      => errorRate,
            'previewCount'   => previewCount,
            'liveCount'      => totalSessions - previewCount
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEventBreakdown() {
        if (Test.isRunningTest() && useMockData) { return mockEventBreakdown; }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT LogType, COUNT(Id) cnt
            FROM ConversationDefinitionEventLog
            GROUP BY LogType
            ORDER BY COUNT(Id) DESC
        ]) {
            results.add(new Map<String, Object>{
                'logType' => (String) ar.get('LogType'),
                'count'   => (Integer) ar.get('cnt')
            });
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getTopicDistribution() {
        if (Test.isRunningTest() && useMockData) { return mockTopicDistribution; }

        Map<String, Integer> topicCounts = new Map<String, Integer>();
        String prefix = 'Topic classification succeeded: ';

        for (ConversationDefinitionEventLog evt : [
            SELECT EventLabel
            FROM ConversationDefinitionEventLog
            WHERE LogType = 'TopicClassificationSuccess'
        ]) {
            String label = evt.EventLabel;
            if (label == null) { continue; }
            String topic = label.startsWith(prefix)
                ? label.substringAfter(prefix).trim()
                : label;
            topicCounts.put(topic, (topicCounts.containsKey(topic) ? topicCounts.get(topic) : 0) + 1);
        }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (String t : topicCounts.keySet()) {
            results.add(new Map<String, Object>{
                'topic' => t,
                'count' => topicCounts.get(t)
            });
        }

        results.sort(new TopicCountComparator());
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getInstructionAdherence() {
        if (Test.isRunningTest() && useMockData) { return mockAdherence; }

        Integer highCount = 0;
        Integer lowCount = 0;
        for (ConversationDefinitionEventLog evt : [
            SELECT EventLabel
            FROM ConversationDefinitionEventLog
            WHERE LogType = 'ResponseEvaluationMetric'
        ]) {
            String label = evt.EventLabel;
            if (label == null) { continue; }
            if (label.containsIgnoreCase('HIGH')) {
                highCount++;
            } else if (label.containsIgnoreCase('LOW')) {
                lowCount++;
            }
        }

        Integer totalEvaluated = highCount + lowCount;
        Decimal adherenceRate = totalEvaluated > 0
            ? ((Decimal) highCount / totalEvaluated * 100).setScale(1)
            : 0;

        return new Map<String, Object>{
            'highCount'      => highCount,
            'lowCount'       => lowCount,
            'totalEvaluated' => totalEvaluated,
            'adherenceRate'  => adherenceRate
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getRecentConversations() {
        if (Test.isRunningTest() && useMockData) { return mockConversations; }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (ConversationDefinitionEventLog evt : [
            SELECT EventLabel, EventDateTime
            FROM ConversationDefinitionEventLog
            WHERE LogType = 'InputMessage'
            ORDER BY EventDateTime DESC
            LIMIT 20
        ]) {
            String label = evt.EventLabel;
            if (label == null || label.containsIgnoreCase('End Session')) { continue; }

            if (label.startsWith('User response: ')) {
                label = label.substringAfter('User response: ');
            }
            // Strip surrounding quotes
            if (label.length() >= 2 && label.startsWith('"') && label.endsWith('"')) {
                label = label.substring(1, label.length() - 1);
            }

            results.add(new Map<String, Object>{
                'prompt'    => label,
                'timestamp' => evt.EventDateTime
            });
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getSessionTrend() {
        if (Test.isRunningTest() && useMockData) { return mockSessionTrend; }

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT DAY_ONLY(SessionStartTime) d, COUNT(Id) cnt
            FROM ConversationDefinitionSession
            GROUP BY DAY_ONLY(SessionStartTime)
            ORDER BY DAY_ONLY(SessionStartTime)
        ]) {
            results.add(new Map<String, Object>{
                'sessionDate' => (Date) ar.get('d'),
                'count'       => (Integer) ar.get('cnt')
            });
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getTokenUsage() {
        if (Test.isRunningTest() && useMockData) { return mockTokenUsage; }

        AggregateResult[] agg = [
            SELECT SUM(NumTokens) total, COUNT(Id) cnt
            FROM ConversationDefinitionEventLog
            WHERE NumTokens != null
        ];

        Object totalRaw = agg[0].get('total');
        if (totalRaw == null) {
            return new Map<String, Object>{
                'available'   => false,
                'totalTokens' => 0,
                'avgPerEvent' => 0,
                'eventCount'  => 0
            };
        }

        Decimal totalTokens = (Decimal) totalRaw;
        Integer eventCount = (Integer) agg[0].get('cnt');
        Decimal avgPerEvent = eventCount > 0
            ? (totalTokens / eventCount).setScale(1)
            : 0;

        return new Map<String, Object>{
            'available'   => true,
            'totalTokens' => totalTokens,
            'avgPerEvent' => avgPerEvent,
            'eventCount'  => eventCount
        };
    }

    private class TopicCountComparator implements Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Integer countA = (Integer) a.get('count');
            Integer countB = (Integer) b.get('count');
            return countB - countA; // DESC
        }
    }
}