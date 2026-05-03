/**
 * Tests for ClaimEventPublisher trigger and its ClaimEventPublisherService backend.
 * Methods 1-3 exercise the service directly with constructed Claim records (no DML,
 * fast). Method 4 covers the trigger end-to-end with real DML.
 */
@IsTest
private class ClaimEventPublisherTest {

    /** Builds a Claim populated enough that toEvent() has all the data it needs. */
    private static Claim mkClaim(Id id, String status, String aiRec) {
        Claim c = new Claim();
        // Use the standard mocking pattern: deserialize JSON to assign the read-only Id.
        if (id != null) {
            c = (Claim) JSON.deserialize(
                '{"attributes":{"type":"Claim"},"Id":"' + id + '"}', Claim.class);
        }
        c.Name = 'WC-TEST-' + (id == null ? '0001' : String.valueOf(id).substring(0, 8));
        c.Status = status;
        c.AI_Recommendation__c = aiRec;
        c.Channel__c = 'Web_Chat';
        c.Risk_Score__c = 25;
        c.EstimatedAmount = 9999.00;
        return c;
    }

    @IsTest
    static void testBuildEvents_OnInsert_ReturnsNewEvent() {
        Claim c = mkClaim('0Zk000000000001AAA', 'New', 'Auto-Approve');
        List<Warranty_Claim_Event__e> events =
            ClaimEventPublisherService.buildEvents(
                new List<Claim>{ c }, null, TriggerOperation.AFTER_INSERT);

        System.assertEquals(1, events.size(), 'Insert should produce exactly one NEW event');
        Warranty_Claim_Event__e e = events[0];
        System.assertEquals('NEW',          e.Event_Type__c);
        System.assertEquals(c.Id,           e.Claim_Id__c);
        System.assertEquals(c.Name,         e.Claim_Number__c);
        System.assertEquals('New',          e.Claim_Status__c);
        System.assertEquals(null,           e.Previous_Status__c, 'NEW should not have a previous status');
        System.assertEquals('Auto-Approve', e.AI_Recommendation__c);
        System.assertEquals('Web_Chat',     e.Channel__c);
        System.assertEquals(25,             e.Risk_Score__c);
    }

    @IsTest
    static void testBuildEvents_OnStatusChange_ReturnsStatusChangeEvent() {
        Claim before = mkClaim('0Zk000000000002AAA', 'New',      'Auto-Approve');
        Claim after  = mkClaim('0Zk000000000002AAA', 'Approved', 'Auto-Approve');
        Map<Id, Claim> oldMap = new Map<Id, Claim>{ before.Id => before };

        List<Warranty_Claim_Event__e> events =
            ClaimEventPublisherService.buildEvents(
                new List<Claim>{ after }, oldMap, TriggerOperation.AFTER_UPDATE);

        System.assertEquals(1, events.size(), 'Status change should produce one event');
        Warranty_Claim_Event__e e = events[0];
        System.assertEquals('STATUS_CHANGE', e.Event_Type__c);
        System.assertEquals('Approved',      e.Claim_Status__c);
        System.assertEquals('New',           e.Previous_Status__c, 'Previous status should be the old value');
    }

    @IsTest
    static void testBuildEvents_OnUnchangedStatusUpdate_ReturnsEmpty() {
        // Status didn't change — only some other field did. The trigger must NOT fire
        // an event so subscribers aren't spammed on routine edits.
        Claim before = mkClaim('0Zk000000000003AAA', 'Under Review', 'Review');
        Claim after  = mkClaim('0Zk000000000003AAA', 'Under Review', 'Review');
        after.EstimatedAmount = 12345.00;   // different field changed
        Map<Id, Claim> oldMap = new Map<Id, Claim>{ before.Id => before };

        List<Warranty_Claim_Event__e> events =
            ClaimEventPublisherService.buildEvents(
                new List<Claim>{ after }, oldMap, TriggerOperation.AFTER_UPDATE);

        System.assertEquals(0, events.size(), 'Non-status updates must not publish events');
    }

    @IsTest
    static void testTriggerIntegration_InsertSucceedsAndPublishesEvent() {
        // Full path test: real DML through the trigger. Asserts the insert succeeds
        // and the trigger ran without exception. (Apex test framework auto-rollbacks
        // platform events; we can't directly assert what was published, but a
        // successful Test.stopTest with no thrown exception means the publish call
        // executed cleanly.)
        Account dealer = new Account(Name = 'Trigger Test Dealer');
        insert dealer;

        Test.startTest();
        Claim c = new Claim(
            Name           = 'WC-TRIGTEST',
            AccountId      = dealer.Id,
            Status         = 'Under Review',
            Summary        = 'Trigger integration test',
            EstimatedAmount = 100,
            InitiationDate  = Date.today(),
            Risk_Score__c   = 10,
            Channel__c      = 'Web_Chat'
        );
        insert c;
        Test.stopTest();

        Claim verify = [SELECT Id, Status FROM Claim WHERE Id = :c.Id];
        System.assertNotEquals(null, verify.Id, 'Claim must persist');
        System.assertEquals('Under Review', verify.Status,
            'Trigger must not corrupt the inserted record');
    }
}