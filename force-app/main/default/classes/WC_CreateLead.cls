public with sharing class WC_CreateLead {

    @InvocableMethod(
        label='Create Lead for Unknown Vehicle'
        description='Creates a Lead record when a VIN lookup finds no matching vehicle. Captures dealer info and vehicle details for sales team follow-up and vehicle onboarding.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        List<Lead> leadsToInsert = new List<Lead>();
        Map<Integer, Integer> leadIdxToOutputIdx = new Map<Integer, Integer>();

        for (Integer i = 0; i < inputs.size(); i++) {
            Input inp = inputs[i];
            Output out = new Output();
            outputs.add(out);

            if (String.isBlank(inp.vinNumber)) {
                out.success = false;
                out.message = 'VIN number is required to create a lead';
                continue;
            }
            if (String.isBlank(inp.dealerName)) {
                out.success = false;
                out.message = 'Dealer name is required to create a lead';
                continue;
            }

            Lead l = new Lead();

            if (String.isNotBlank(inp.contactName)) {
                List<String> nameParts = inp.contactName.trim().split('\\s+', 2);
                if (nameParts.size() > 1) {
                    l.FirstName = nameParts[0];
                    l.LastName = nameParts[1];
                } else {
                    l.LastName = nameParts[0];
                }
            } else {
                l.LastName = inp.dealerName;
            }

            l.Company = inp.dealerName;
            l.Email = inp.contactEmail;
            l.Phone = inp.contactPhone;
            l.LeadSource = 'Agentforce - Warranty Inquiry';
            l.Status = 'New';

            String leadDesc = 'VIN not found: ' + inp.vinNumber;
            if (String.isNotBlank(inp.vehicleDetails)) {
                leadDesc += '\nVehicle Details: ' + inp.vehicleDetails;
            }
            if (String.isNotBlank(inp.inquiryNotes)) {
                leadDesc += '\nInquiry: ' + inp.inquiryNotes;
            }
            l.Description = leadDesc;

            Integer leadIdx = leadsToInsert.size();
            leadsToInsert.add(l);
            leadIdxToOutputIdx.put(leadIdx, i);
        }

        if (!leadsToInsert.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(leadsToInsert, false);

            for (Integer j = 0; j < results.size(); j++) {
                Integer outIdx = leadIdxToOutputIdx.get(j);
                Output out = outputs[outIdx];
                Input inp = inputs[outIdx];

                if (results[j].isSuccess()) {
                    out.success = true;
                    out.leadId = leadsToInsert[j].Id;
                    out.message = 'Lead created for follow-up. VIN ' + inp.vinNumber + ' will be investigated.';
                } else {
                    out.success = false;
                    out.message = 'Failed to create lead: ' + results[j].getErrors()[0].getMessage();
                }
            }
        }

        return outputs;
    }

    /**
     * @AuraEnabled wrapper for LWC chat. Same logic as the InvocableMethod above.
     */
    @AuraEnabled
    public static Map<String, Object> createFromChat(String contactName, String contactPhone,
                                                      String contactEmail, String vehicleDetails,
                                                      String inquiryNotes, String dealerName, String vinNumber) {
        try {
            Input inp = new Input();
            inp.contactName    = contactName;
            inp.contactPhone   = contactPhone;
            inp.contactEmail   = contactEmail;
            inp.vehicleDetails = vehicleDetails;
            inp.inquiryNotes   = inquiryNotes;
            inp.dealerName     = String.isNotBlank(dealerName) ? dealerName : 'Electra Dealer';
            inp.vinNumber      = String.isNotBlank(vinNumber) ? vinNumber : 'UNKNOWN-VIN-' + Datetime.now().getTime();
            List<Output> outs = execute(new List<Input>{ inp });
            if (outs.isEmpty()) throw new AuraHandledException('No result from lead creation');
            Output o = outs[0];
            return new Map<String, Object>{
                'success' => o.success,
                'leadId'  => o.leadId,
                'message' => o.message
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw new AuraHandledException('Lead creation failed: ' + e.getMessage()); }
    }

    public class Input {
        @InvocableVariable(required=true label='VIN Number'
            description='The VIN that was not found in our vehicle database')
        public String vinNumber;

        @InvocableVariable(required=true label='Dealer Name'
            description='Name of the dealer submitting the inquiry')
        public String dealerName;

        @InvocableVariable(label='Contact Name'
            description='Name of the dealer contact person')
        public String contactName;

        @InvocableVariable(label='Contact Email'
            description='Email of the dealer contact')
        public String contactEmail;

        @InvocableVariable(label='Contact Phone'
            description='Phone number of the dealer contact')
        public String contactPhone;

        @InvocableVariable(label='Vehicle Details'
            description='Any known details about the vehicle (make, model, year)')
        public String vehicleDetails;

        @InvocableVariable(label='Inquiry Notes'
            description='Additional context about the inquiry')
        public String inquiryNotes;
    }

    public class Output {
        @InvocableVariable(label='Success' description='True if the Lead was created successfully')
        public Boolean success;

        @InvocableVariable(label='Lead Id' description='Salesforce ID of the created Lead')
        public String leadId;

        @InvocableVariable(label='Message' description='Confirmation or error message')
        public String message;
    }
}