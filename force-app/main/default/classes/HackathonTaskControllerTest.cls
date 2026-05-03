@IsTest
private class HackathonTaskControllerTest {

    private static Hackathon_Task__c insertTask(String status) {
        Hackathon_Task__c t = new Hackathon_Task__c(
            Name = 'T-UNIT-' + String.valueOf(Math.abs(Crypto.getRandomLong())),
            Plan__c = 'P1 - Custom Fields',
            Phase__c = 'Phase 1 - Foundation',
            Task_Description__c = 'Unit test hackathon task',
            Owner_Name__c = 'Santosh',
            Priority__c = 'MANDATORY',
            Status__c = status,
            Target_Day__c = 'D1',
            Sort_Order__c = 1
        );
        insert t;
        return t;
    }

    @IsTest
    static void getTasks_returnsRows() {
        insertTask('READY');
        Test.startTest();
        List<Hackathon_Task__c> rows = HackathonTaskController.getTasks();
        Test.stopTest();
        System.assert(!rows.isEmpty(), 'expected tasks');
    }

    @IsTest
    static void getStats_hasTotal() {
        insertTask('DONE');
        Test.startTest();
        Map<String, Object> stats = HackathonTaskController.getStats();
        Test.stopTest();
        System.assertEquals(1, (Integer) stats.get('total'));
        System.assertNotEquals(null, stats.get('byOwner'));
    }

    @IsTest
    static void updateTask_setsDoneAndNotifies() {
        Hackathon_Task__c t = insertTask('READY');
        Test.startTest();
        HackathonTaskController.updateTask(t.Id, 'DONE', null, null);
        Test.stopTest();
        t = [SELECT Completed_Date__c FROM Hackathon_Task__c WHERE Id = :t.Id];
        System.assertNotEquals(null, t.Completed_Date__c);
    }

    @IsTest
    static void updateTaskStatus_clearsDateWhenNotDone() {
        Hackathon_Task__c t = insertTask('DONE');
        update new Hackathon_Task__c(Id = t.Id, Completed_Date__c = Datetime.now());
        Test.startTest();
        HackathonTaskController.updateTaskStatus(t.Id, 'READY', null);
        Test.stopTest();
        t = [SELECT Completed_Date__c FROM Hackathon_Task__c WHERE Id = :t.Id];
        System.assertEquals(null, t.Completed_Date__c);
    }

    @IsTest
    static void updateTaskNotes_and_Blocker() {
        Hackathon_Task__c t = insertTask('READY');
        HackathonTaskController.updateTaskNotes(t.Id, 'Electra note');
        HackathonTaskController.updateTaskBlocker(t.Id, 'Blocked on org');
        t = [SELECT Notes__c, Blocker__c FROM Hackathon_Task__c WHERE Id = :t.Id];
        System.assertEquals('Electra note', t.Notes__c);
        System.assertEquals('Blocked on org', t.Blocker__c);
    }

    @IsTest
    static void createTask_and_updateTaskFull_and_deleteTask() {
        Test.startTest();
        Id newId = HackathonTaskController.createTask(
            'T-NEW-001', 'P2 - Sample Data', 'Phase 2 - Core Build',
            'Created from test', 'Pooja', 'HIGH VALUE', 'IN PROGRESS',
            'D2', 'P0.01', 'Verify wiring', 'Initial notes', '', 99
        );
        HackathonTaskController.updateTaskFull(
            newId, 'T-NEW-002', 'P3 - Apex Classes', 'Phase 3 - Integration',
            'Updated desc', 'Piyush', 'STRETCH', 'TESTING',
            'D3', 'P1.02', 'Verify again', 'Notes here', 'No blocker', 100
        );
        HackathonTaskController.deleteTask(newId);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Hackathon_Task__c WHERE Id = :newId]);
    }

    @IsTest
    static void sendStatusNotificationAsync_handlesGracefully() {
        Hackathon_Task__c t = insertTask('READY');
        Test.startTest();
        HackathonTaskController.sendStatusNotificationAsync(
            t.Id, t.Name, 'DONE', 'Test User', UserInfo.getUserId()
        );
        Test.stopTest();
    }

    @IsTest
    static void getTaskTesterUserOptions_returnsRows() {
        Test.startTest();
        List<HackathonTaskController.TesterOption> opts = HackathonTaskController.getTaskTesterUserOptions();
        Test.stopTest();
        System.assertNotEquals(null, opts);
    }

    @IsTest
    static void updateTesterUserId_setsLookupWhenTesting() {
        Hackathon_Task__c t = insertTask('TESTING');
        Id testerId = UserInfo.getUserId();
        Test.startTest();
        HackathonTaskController.updateTesterUserId(t.Id, String.valueOf(testerId));
        Test.stopTest();
        Hackathon_Task__c afterRow = [
            SELECT tester_userId__c, tester_userId__r.Name, tester_userId__r.FirstName
            FROM Hackathon_Task__c
            WHERE Id = :t.Id
        ];
        System.assertEquals(testerId, afterRow.tester_userId__c);
        System.assert(
            String.isNotBlank(afterRow.tester_userId__r.FirstName)
            || String.isNotBlank(afterRow.tester_userId__r.Name),
            'expected User relationship for tester lookup'
        );
    }

    @IsTest
    static void updateTesterUserId_rejectsNonTesting() {
        Hackathon_Task__c t = insertTask('READY');
        Boolean threw = false;
        Test.startTest();
        try {
            HackathonTaskController.updateTesterUserId(t.Id, String.valueOf(UserInfo.getUserId()));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'expected guard when status is not TESTING');
    }

    @IsTest
    static void updateTesterUserId_rejectsInvalidUser() {
        Hackathon_Task__c t = insertTask('TESTING');
        Boolean threw = false;
        Test.startTest();
        try {
            HackathonTaskController.updateTesterUserId(t.Id, UserInfo.getOrganizationId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'expected invalid user id');
    }

    @IsTest
    static void getComments_create_delete_roundTrip() {
        Hackathon_Task__c t = insertTask('READY');
        Test.startTest();
        System.assertEquals(0, HackathonTaskController.getComments(t.Id).size());
        HackathonTaskController.createComment(t.Id, '<p>Electra mention @Santosh</p>', 'Unit Author');
        System.assertEquals(1, HackathonTaskController.getComments(t.Id).size());
        Id cId = HackathonTaskController.getComments(t.Id)[0].Id;
        HackathonTaskController.deleteComment(cId);
        Test.stopTest();
        System.assertEquals(0, HackathonTaskController.getComments(t.Id).size());
    }

    @IsTest
    static void sendNotification_coversAllStatusColors() {
        Hackathon_Task__c t = insertTask('READY');
        Test.startTest();
        HackathonTaskController.sendStatusNotificationAsync(
            t.Id, t.Name, 'BLOCKED', 'Piyush Bhanegaonkar', UserInfo.getUserId()
        );
        HackathonTaskController.sendStatusNotificationAsync(
            t.Id, t.Name, 'IN PROGRESS', 'Pooja Bankar', UserInfo.getUserId()
        );
        HackathonTaskController.sendStatusNotificationAsync(
            t.Id, t.Name, 'TESTING', 'Sonal Agarwal', UserInfo.getUserId()
        );
        HackathonTaskController.sendStatusNotificationAsync(
            t.Id, t.Name, 'READY', 'Santosh Ulbetti', UserInfo.getUserId()
        );
        Test.stopTest();
    }
}