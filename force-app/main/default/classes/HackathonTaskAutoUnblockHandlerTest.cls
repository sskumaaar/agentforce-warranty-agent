@IsTest
private class HackathonTaskAutoUnblockHandlerTest {

    private static Hackathon_Task__c makeTask(String name, String status, String dependsOn) {
        return new Hackathon_Task__c(
            Name = name,
            Plan__c = 'P1 - Custom Fields',
            Phase__c = 'Phase 1 - Foundation',
            Task_Description__c = 'Test task ' + name,
            Owner_Name__c = 'Piyush',
            Priority__c = 'MANDATORY',
            Status__c = status,
            Target_Day__c = 'D1',
            Depends_On__c = dependsOn,
            Sort_Order__c = 1
        );
    }

    @IsTest
    static void completingBlocker_unblocksDependent() {
        Hackathon_Task__c blocker = makeTask('P0.01', 'IN PROGRESS', null);
        insert blocker;

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01');
        blocked.Blocker__c = 'Waiting on P0.01';
        insert blocked;

        Test.startTest();
        blocker.Status__c = 'DONE';
        update blocker;
        Test.stopTest();

        blocked = [SELECT Status__c, Blocker__c, Notes__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('READY', blocked.Status__c, 'Dependent task should auto-unblock');
        System.assertEquals(null, blocked.Blocker__c, 'Blocker field should be cleared');
        System.assert(blocked.Notes__c.contains('Auto-unblocked'), 'Notes should indicate auto-unblock');
    }

    @IsTest
    static void movingBlockerToTesting_unblocksDependent() {
        Hackathon_Task__c blocker = makeTask('P0.01', 'IN PROGRESS', null);
        insert blocker;

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01');
        blocked.Blocker__c = 'Waiting on P0.01';
        insert blocked;

        Test.startTest();
        blocker.Status__c = 'TESTING';
        update blocker;
        Test.stopTest();

        blocked = [SELECT Status__c, Blocker__c, Notes__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('READY', blocked.Status__c, 'TESTING should satisfy dependency for unblock');
        System.assertEquals(null, blocked.Blocker__c, 'Blocker field should be cleared');
        System.assert(blocked.Notes__c.contains('delivered or verified'), 'Notes should describe TESTING/DONE gate');
    }

    @IsTest
    static void multipleDepsMet_allDependenciesMustBeDone() {
        Hackathon_Task__c dep1 = makeTask('P0.01', 'DONE', null);
        Hackathon_Task__c dep2 = makeTask('P0.02', 'IN PROGRESS', null);
        insert new List<Hackathon_Task__c>{ dep1, dep2 };

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01, P0.02');
        blocked.Blocker__c = 'Waiting on P0.01 and P0.02';
        insert blocked;

        Test.startTest();
        dep2.Status__c = 'DONE';
        update dep2;
        Test.stopTest();

        blocked = [SELECT Status__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('READY', blocked.Status__c, 'Should unblock when ALL deps are DONE');
    }

    @IsTest
    static void multipleDepsMet_testingCountsSameAsDone() {
        Hackathon_Task__c dep1 = makeTask('P0.01', 'DONE', null);
        Hackathon_Task__c dep2 = makeTask('P0.02', 'IN PROGRESS', null);
        insert new List<Hackathon_Task__c>{ dep1, dep2 };

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01, P0.02');
        blocked.Blocker__c = 'Waiting on P0.01 and P0.02';
        insert blocked;

        Test.startTest();
        dep2.Status__c = 'TESTING';
        update dep2;
        Test.stopTest();

        blocked = [SELECT Status__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('READY', blocked.Status__c, 'TESTING should satisfy dep alongside DONE');
    }

    @IsTest
    static void partialDeps_staysBlocked() {
        Hackathon_Task__c dep1 = makeTask('P0.01', 'DONE', null);
        Hackathon_Task__c dep2 = makeTask('P0.02', 'IN PROGRESS', null);
        insert new List<Hackathon_Task__c>{ dep1, dep2 };

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01, P0.02');
        blocked.Blocker__c = 'Waiting on both';
        insert blocked;

        Test.startTest();
        dep1.Status__c = 'DONE';
        update dep1;
        Test.stopTest();

        blocked = [SELECT Status__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('BLOCKED', blocked.Status__c, 'Should stay blocked until all deps are TESTING or DONE');
    }

    @IsTest
    static void unrelatedCompletion_noEffect() {
        Hackathon_Task__c unrelated = makeTask('P0.99', 'IN PROGRESS', null);
        insert unrelated;

        Hackathon_Task__c blocked = makeTask('P1.01', 'BLOCKED', 'P0.01');
        blocked.Blocker__c = 'Waiting on P0.01';
        insert blocked;

        Test.startTest();
        unrelated.Status__c = 'DONE';
        update unrelated;
        Test.stopTest();

        blocked = [SELECT Status__c FROM Hackathon_Task__c WHERE Id = :blocked.Id];
        System.assertEquals('BLOCKED', blocked.Status__c, 'Unrelated completion should not unblock');
    }

    @IsTest
    static void noDone_noAction() {
        Hackathon_Task__c t = makeTask('P0.01', 'READY', null);
        insert t;

        Test.startTest();
        t.Status__c = 'IN PROGRESS';
        update t;
        Test.stopTest();
    }
}