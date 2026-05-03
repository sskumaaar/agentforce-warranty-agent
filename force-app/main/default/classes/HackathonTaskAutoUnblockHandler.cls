public without sharing class HackathonTaskAutoUnblockHandler {

    private static Boolean isProcessing = false;

    public static void handleAfterUpdate(
        List<Hackathon_Task__c> newTasks,
        Map<Id, Hackathon_Task__c> oldMap
    ) {
        if (isProcessing) return;

        Set<String> newlySatisfiedNames = new Set<String>();
        for (Hackathon_Task__c t : newTasks) {
            Hackathon_Task__c old = oldMap.get(t.Id);
            if (transitionedToDeliveredOrVerified(t.Status__c, old.Status__c)) {
                newlySatisfiedNames.add(t.Name);
            }
        }
        if (newlySatisfiedNames.isEmpty()) return;

        List<Hackathon_Task__c> blockedTasks = [
            SELECT Id, Name, Status__c, Depends_On__c, Owner_Name__c
            FROM Hackathon_Task__c
            WHERE Status__c = 'BLOCKED' AND Depends_On__c != null
        ];
        if (blockedTasks.isEmpty()) return;

        Set<String> satisfiedDepNames = new Set<String>();
        for (Hackathon_Task__c d : [
            SELECT Name FROM Hackathon_Task__c WHERE Status__c IN ('DONE', 'TESTING')
        ]) {
            satisfiedDepNames.add(d.Name);
        }
        satisfiedDepNames.addAll(newlySatisfiedNames);

        List<Hackathon_Task__c> toUnblock = new List<Hackathon_Task__c>();
        Map<Id, String> unblockedTaskNames = new Map<Id, String>();

        for (Hackathon_Task__c blocked : blockedTasks) {
            Boolean relevant = false;
            Boolean allDepsMet = true;

            for (String dep : blocked.Depends_On__c.split('[,;\\s]+')) {
                String d = dep.trim();
                if (String.isBlank(d)) continue;
                if (newlySatisfiedNames.contains(d)) {
                    relevant = true;
                }
                if (!satisfiedDepNames.contains(d)) {
                    allDepsMet = false;
                }
            }

            if (relevant && allDepsMet) {
                String note = 'Auto-unblocked: ' +
                    String.join(new List<String>(newlySatisfiedNames), ', ') +
                    ' delivered or verified (TESTING or DONE)';
                toUnblock.add(new Hackathon_Task__c(
                    Id = blocked.Id,
                    Status__c = 'READY',
                    Blocker__c = null,
                    Notes__c = note
                ));
                unblockedTaskNames.put(blocked.Id, blocked.Name);
            }
        }

        if (toUnblock.isEmpty()) return;

        isProcessing = true;
        try {
            update toUnblock;
            for (Hackathon_Task__c t : toUnblock) {
                String taskName = unblockedTaskNames.get(t.Id);
                HackathonTaskController.sendStatusNotificationAsync(
                    t.Id, taskName, 'READY',
                    'Auto-Unblock System', UserInfo.getUserId()
                );
            }
        } finally {
            isProcessing = false;
        }
    }

    private static Boolean transitionedToDeliveredOrVerified(String newStatus, String oldStatus) {
        if (newStatus != 'DONE' && newStatus != 'TESTING') {
            return false;
        }
        if (oldStatus == 'DONE' || oldStatus == 'TESTING') {
            return false;
        }
        return true;
    }
}