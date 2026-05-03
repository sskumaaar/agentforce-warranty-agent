public with sharing class HackathonTaskController {

    public class TesterOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class TaskFileRow {
        @AuraEnabled public String id;
        @AuraEnabled public String title;
        @AuraEnabled public String ext;
        @AuraEnabled public Long size;
        @AuraEnabled public String versionId;
    }

    public class MentionRow {
        @AuraEnabled public Id taskId;
        @AuraEnabled public String taskName;
        @AuraEnabled public String taskDesc;
        @AuraEnabled public String author;
        @AuraEnabled public String body;
        @AuraEnabled public Datetime createdDate;
    }

    private static String fieldKeyIgnoreCase(Map<String, Schema.SObjectField> fm, String apiName) {
        for (String k : fm.keySet()) {
            if (k != null && k.equalsIgnoreCase(apiName)) {
                return k;
            }
        }
        return null;
    }

    private static void addFieldToken(Map<String, Schema.SObjectField> fm, Set<String> tokens, String apiName) {
        String k = fieldKeyIgnoreCase(fm, apiName);
        if (k != null) {
            tokens.add(fm.get(k).getDescribe().getName());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Hackathon_Task__c> getTasks() {
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Hackathon_Task__c.fields.getMap();
        Set<String> tokens = new Set<String>{
            'Id', 'Name', 'Plan__c', 'Phase__c', 'Task_Description__c', 'Owner_Name__c', 'Priority__c', 'Status__c',
            'Target_Day__c', 'Notes__c', 'Verification__c', 'Completed_Date__c', 'Blocker__c', 'Depends_On__c',
            'Sort_Order__c', 'LastModifiedDate', 'LastModifiedBy.Name'
        };
        addFieldToken(fm, tokens, 'Task_Detail__c');
        addFieldToken(fm, tokens, 'Tested_By__c');
        addFieldToken(fm, tokens, 'Test_Remarks__c');
        String testerKey = fieldKeyIgnoreCase(fm, 'tester_userId__c');
        if (testerKey != null) {
            tokens.add(fm.get(testerKey).getDescribe().getName());
            tokens.add('tester_userId__r.FirstName');
            tokens.add('tester_userId__r.Name');
        }
        String testedKey = fieldKeyIgnoreCase(fm, 'Tested_By__c');
        Schema.SObjectField testedF = testedKey == null ? null : fm.get(testedKey);
        if (testedF != null && testedF.getDescribe().getReferenceTo().size() > 0
            && testedF.getDescribe().getReferenceTo()[0] == User.SObjectType) {
            tokens.add('Tested_By__r.FirstName');
            tokens.add('Tested_By__r.Name');
        }
        List<String> ordered = new List<String>(tokens);
        ordered.sort();
        String soql = 'SELECT ' + String.join(ordered, ', ') +
            ' FROM Hackathon_Task__c ORDER BY Sort_Order__c ASC NULLS LAST, Name ASC';
        return Database.query(soql);
    }

    @AuraEnabled(cacheable=true)
    public static List<TesterOption> getTaskTesterUserOptions() {
        List<TesterOption> out = new List<TesterOption>();
        for (User u : [
            SELECT Id, FirstName, Name FROM User
            WHERE IsActive = true
              AND Profile.Name = 'System Administrator'
            ORDER BY FirstName ASC NULLS LAST, Name ASC
            LIMIT 200
        ]) {
            TesterOption row = new TesterOption();
            row.label = String.isNotBlank(u.FirstName) ? u.FirstName.trim() : u.Name;
            row.value = String.valueOf(u.Id);
            out.add(row);
        }
        return out;
    }

    @AuraEnabled
    public static void updateTesterUserId(Id taskId, String userIdString) {
        Hackathon_Task__c t = [
            SELECT Id, Status__c FROM Hackathon_Task__c WHERE Id = :taskId LIMIT 1
        ];
        if (t.Status__c != 'TESTING') {
            throw new AuraHandledException(
                'Electra Cars hackathon tracker: testing assignment is only editable when the task status is TESTING.'
            );
        }
        Id assignId = null;
        if (!String.isBlank(userIdString)) {
            try {
                assignId = (Id) userIdString;
            } catch (Exception ex) {
                throw new AuraHandledException(
                    'Electra Cars hackathon tracker: invalid user id for testing assignment.'
                );
            }
            String sid = String.valueOf(assignId);
            if (!sid.startsWith('005') || sid.length() < 15) {
                throw new AuraHandledException(
                    'Electra Cars hackathon tracker: testing assignment must be a Salesforce User Id.'
                );
            }
            List<User> users = [
                SELECT Id FROM User WHERE Id = :assignId AND IsActive = true LIMIT 1
            ];
            if (users.isEmpty()) {
                throw new AuraHandledException(
                    'Electra Cars hackathon tracker: selected tester must be an active Salesforce user.'
                );
            }
        }
        Map<String, Schema.SObjectField> tfm = Schema.SObjectType.Hackathon_Task__c.fields.getMap();
        String testerFieldKey = fieldKeyIgnoreCase(tfm, 'tester_userId__c');
        if (testerFieldKey == null) {
            throw new AuraHandledException(
                'Electra Cars hackathon tracker: tester_userId__c is not available on Hackathon_Task__c.'
            );
        }
        String testerApi = tfm.get(testerFieldKey).getDescribe().getName();
        SObject row = Hackathon_Task__c.SObjectType.newSObject(taskId);
        row.put(testerApi, assignId);
        update row;
    }

    @AuraEnabled
    public static void updateTestRemarks(Id taskId, String remarks) {
        String k = fieldKeyIgnoreCase(Schema.SObjectType.Hackathon_Task__c.fields.getMap(), 'Test_Remarks__c');
        if (k == null) {
            throw new AuraHandledException(
                'Electra Cars hackathon tracker: Test_Remarks__c is not available on this org.'
            );
        }
        String api = Schema.SObjectType.Hackathon_Task__c.fields.getMap().get(k).getDescribe().getName();
        SObject row = Hackathon_Task__c.SObjectType.newSObject(taskId);
        row.put(api, remarks);
        update row;
    }

    @AuraEnabled
    public static void updateTestedBy(Id taskId, String testedBy) {
        String k = fieldKeyIgnoreCase(Schema.SObjectType.Hackathon_Task__c.fields.getMap(), 'Tested_By__c');
        if (k == null) {
            return;
        }
        Schema.DescribeFieldResult d = Schema.SObjectType.Hackathon_Task__c.fields.getMap().get(k).getDescribe();
        SObject row = Hackathon_Task__c.SObjectType.newSObject(taskId);
        if (d.getType() == DisplayType.REFERENCE && d.getReferenceTo().size() > 0
            && d.getReferenceTo()[0] == User.SObjectType) {
            if (String.isBlank(testedBy)) {
                row.put(d.getName(), null);
            } else {
                try {
                    row.put(d.getName(), (Id) testedBy);
                } catch (Exception ex) {
                    throw new AuraHandledException(
                        'Electra Cars hackathon tracker: Tested_By__c expects a Salesforce User Id in this org.'
                    );
                }
            }
        } else {
            row.put(d.getName(), testedBy);
        }
        update row;
    }

    @AuraEnabled(cacheable=true)
    public static List<Hackathon_Task_Comment__c> getComments(Id taskId) {
        return [
            SELECT Id, Body__c, Author_Name__c, CreatedDate, CreatedById
            FROM Hackathon_Task_Comment__c
            WHERE Task__c = :taskId
            ORDER BY CreatedDate ASC
        ];
    }

    @AuraEnabled
    public static void createComment(Id taskId, String body, String authorName) {
        if (String.isBlank(body)) {
            throw new AuraHandledException('Electra Cars hackathon tracker: comment body is required.');
        }
        insert new Hackathon_Task_Comment__c(
            Task__c = taskId,
            Body__c = body,
            Author_Name__c = authorName
        );
    }

    @AuraEnabled
    public static void deleteComment(Id commentId) {
        delete [SELECT Id FROM Hackathon_Task_Comment__c WHERE Id = :commentId LIMIT 1];
    }

    @AuraEnabled(cacheable=true)
    public static List<TaskFileRow> getTaskFiles(Id taskId) {
        List<TaskFileRow> rows = new List<TaskFileRow>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension,
                   ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :taskId
            ORDER BY ContentDocument.Title ASC
        ]) {
            TaskFileRow r = new TaskFileRow();
            r.id = String.valueOf(link.ContentDocumentId);
            r.title = link.ContentDocument.Title;
            r.ext = link.ContentDocument.FileExtension;
            r.size = link.ContentDocument.ContentSize;
            r.versionId = String.valueOf(link.ContentDocument.LatestPublishedVersionId);
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled
    public static void deleteTaskFile(Id taskId, Id contentDocumentId) {
        List<ContentDocumentLink> links = [
            SELECT Id FROM ContentDocumentLink
            WHERE LinkedEntityId = :taskId AND ContentDocumentId = :contentDocumentId
            LIMIT 10
        ];
        if (links.isEmpty()) {
            throw new AuraHandledException(
                'Electra Cars hackathon tracker: that file is not attached to this hackathon task.'
            );
        }
        delete links;
    }

    @AuraEnabled(cacheable=true)
    public static List<MentionRow> getMyMentions(String ownerName) {
        List<MentionRow> out = new List<MentionRow>();
        if (String.isBlank(ownerName)) {
            return out;
        }
        final String token = '@' + ownerName;
        for (Hackathon_Task_Comment__c c : [
            SELECT Id, Body__c, Author_Name__c, CreatedDate, Task__r.Id, Task__r.Name, Task__r.Task_Description__c
            FROM Hackathon_Task_Comment__c
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            if (c.Body__c == null || !c.Body__c.containsIgnoreCase(token)) {
                continue;
            }
            MentionRow m = new MentionRow();
            m.taskId = c.Task__r.Id;
            m.taskName = c.Task__r.Name;
            m.taskDesc = c.Task__r.Task_Description__c;
            m.author = c.Author_Name__c;
            m.body = c.Body__c;
            m.createdDate = c.CreatedDate;
            out.add(m);
            if (out.size() >= 80) {
                break;
            }
        }
        return out;
    }

    @AuraEnabled
    public static void updateTask(Id taskId, String status, String notes, String blocker) {
        Hackathon_Task__c old = [SELECT Status__c, Name FROM Hackathon_Task__c WHERE Id = :taskId LIMIT 1];
        Hackathon_Task__c task = new Hackathon_Task__c(Id = taskId);
        if (status != null) {
            task.Status__c = status;
            task.Completed_Date__c = status == 'DONE' ? Datetime.now() : null;
        }
        if (notes != null) task.Notes__c = notes;
        if (blocker != null) task.Blocker__c = blocker;
        update task;
        if (status != null && status != old.Status__c) {
            sendStatusNotificationAsync(taskId, old.Name, status, UserInfo.getName(), UserInfo.getUserId());
        }
    }

    @AuraEnabled
    public static void updateTaskStatus(Id taskId, String status, String notes) {
        Hackathon_Task__c old = [SELECT Status__c, Name FROM Hackathon_Task__c WHERE Id = :taskId LIMIT 1];
        Hackathon_Task__c task = new Hackathon_Task__c(Id = taskId, Status__c = status);
        if (notes != null) task.Notes__c = notes;
        task.Completed_Date__c = status == 'DONE' ? Datetime.now() : null;
        update task;
        if (status != old.Status__c) {
            sendStatusNotificationAsync(taskId, old.Name, status, UserInfo.getName(), UserInfo.getUserId());
        }
    }

    @AuraEnabled
    public static void updateTaskNotes(Id taskId, String notes) {
        update new Hackathon_Task__c(Id = taskId, Notes__c = notes);
    }

    @AuraEnabled
    public static void updateTaskBlocker(Id taskId, String blocker) {
        update new Hackathon_Task__c(Id = taskId, Blocker__c = blocker);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStats() {
        Map<String, Object> stats = new Map<String, Object>();
        for (AggregateResult ar : [
            SELECT Status__c, COUNT(Id) cnt FROM Hackathon_Task__c GROUP BY Status__c
        ]) {
            stats.put((String) ar.get('Status__c'), ar.get('cnt'));
        }
        Map<String, Integer> ownerCounts = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Owner_Name__c, COUNT(Id) cnt FROM Hackathon_Task__c GROUP BY Owner_Name__c
        ]) {
            ownerCounts.put((String) ar.get('Owner_Name__c'), (Integer) ar.get('cnt'));
        }
        stats.put('byOwner', ownerCounts);
        stats.put('total', [SELECT COUNT() FROM Hackathon_Task__c]);
        return stats;
    }

    @AuraEnabled
    public static Id createTask(
        String taskKey, String plan, String phase, String description,
        String ownerName, String priority, String status, String targetDay,
        String dependsOn, String verification, String notes, String blocker,
        Decimal sortOrder
    ) {
        Hackathon_Task__c t = new Hackathon_Task__c(
            Name = taskKey, Plan__c = plan, Phase__c = phase,
            Task_Description__c = description, Owner_Name__c = ownerName,
            Priority__c = priority,
            Status__c = String.isNotBlank(status) ? status : 'READY',
            Target_Day__c = targetDay, Depends_On__c = dependsOn,
            Verification__c = verification, Notes__c = notes,
            Blocker__c = blocker, Sort_Order__c = sortOrder
        );
        if (t.Status__c == 'DONE') t.Completed_Date__c = Datetime.now();
        insert t;
        return t.Id;
    }

    @AuraEnabled
    public static void updateTaskFull(
        Id recordId, String taskKey, String plan, String phase,
        String description, String ownerName, String priority, String status,
        String targetDay, String dependsOn, String verification,
        String notes, String blocker, Decimal sortOrder
    ) {
        Hackathon_Task__c old = [SELECT Status__c FROM Hackathon_Task__c WHERE Id = :recordId LIMIT 1];
        Hackathon_Task__c t = new Hackathon_Task__c(
            Id = recordId, Name = taskKey, Plan__c = plan, Phase__c = phase,
            Task_Description__c = description, Owner_Name__c = ownerName,
            Priority__c = priority, Status__c = status, Target_Day__c = targetDay,
            Depends_On__c = dependsOn, Verification__c = verification,
            Notes__c = notes, Blocker__c = blocker, Sort_Order__c = sortOrder,
            Completed_Date__c = status == 'DONE' ? Datetime.now() : null
        );
        update t;
        if (status != old.Status__c) {
            sendStatusNotificationAsync(recordId, taskKey, status, UserInfo.getName(), UserInfo.getUserId());
        }
    }

    @AuraEnabled
    public static void deleteTask(Id taskId) {
        delete [SELECT Id FROM Hackathon_Task__c WHERE Id = :taskId LIMIT 1];
    }

    @future
    public static void sendStatusNotificationAsync(
        Id taskId, String taskName, String newStatus,
        String changedByName, Id changedByUserId
    ) {
        try {
            List<User> teamUsers = [
                SELECT Id, Email, Name FROM User
                WHERE IsActive = true
                  AND Profile.Name = 'System Administrator'
                  AND Id != :changedByUserId
            ];
            if (teamUsers.isEmpty()) return;

            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Hackathon_Task_Update' LIMIT 1
            ];
            if (!types.isEmpty()) {
                Set<String> recipientIds = new Set<String>();
                for (User u : teamUsers) recipientIds.add(u.Id);
                Messaging.CustomNotification bell = new Messaging.CustomNotification();
                bell.setTitle(taskName + ' \u2192 ' + newStatus);
                bell.setBody(changedByName + ' updated this task');
                bell.setNotificationTypeId(types[0].Id);
                bell.setTargetId(taskId);
                bell.send(recipientIds);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Task notification failed: ' + e.getMessage());
        }
    }
}