public with sharing class WC_PartSearch {

    @InvocableMethod(
        label='Search Spare Parts'
        description='Searches the Product2 parts catalog by name, code, or category. Returns matching parts with pricing for warranty claim creation.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        for (Input inp : inputs) {
            outputs.add(processInput(inp));
        }
        return outputs;
    }

    private static Output processInput(Input inp) {
        Output out = new Output();

        if (String.isBlank(inp.searchTerm) && String.isBlank(inp.category)) {
            out.partsFound = false;
            out.totalMatches = 0;
            out.message = 'Please provide a search term or category to find parts';
            return out;
        }

        Integer resultLimit = (inp.maxResults != null && inp.maxResults > 0)
            ? Math.min(inp.maxResults, 20) : 5;

        try {
            List<Product2> parts;
            Boolean canUseSosl = Limits.getSoslQueries() < Limits.getLimitSoslQueries();

            if (canUseSosl) {
                parts = searchBySosl(inp.searchTerm, inp.category, resultLimit);
            } else {
                parts = new List<Product2>();
            }

            if (parts.isEmpty() && String.isNotBlank(inp.searchTerm)) {
                parts = searchBySoql(inp.searchTerm, inp.category, resultLimit);
            }

            if (parts.isEmpty()) {
                out.partsFound = false;
                out.totalMatches = 0;
                String term = String.isNotBlank(inp.searchTerm) ? inp.searchTerm : inp.category;
                out.message = 'No parts found for: ' + term;
                return out;
            }

            Product2 best = parts[0];
            out.partsFound = true;
            out.partId = best.Id;
            out.partName = best.Name;
            out.partCode = best.ProductCode;
            out.partFamily = best.Family;
            out.totalMatches = parts.size();

            List<String> lines = new List<String>();
            for (Integer i = 0; i < parts.size(); i++) {
                Product2 p = parts[i];
                String code = String.isNotBlank(p.ProductCode) ? p.ProductCode : 'N/A';
                String family = String.isNotBlank(p.Family) ? p.Family : '';
                String line = (i + 1) + '. ' + p.Name + ' (' + code + ')';
                if (String.isNotBlank(family)) {
                    line += ' - ' + family;
                }
                lines.add(line);
            }
            out.resultsSummary = String.join(lines, '\n');
            out.message = 'Found ' + parts.size() + ' matching part(s)';

        } catch (Exception e) {
            out.partsFound = false;
            out.totalMatches = 0;
            out.message = 'Error searching parts: ' + e.getMessage();
        }

        return out;
    }

    private static List<Product2> searchBySosl(String searchTerm, String category, Integer resultLimit) {
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return new List<Product2>();
        }

        String sanitized = String.escapeSingleQuotes(searchTerm) + '*';
        String soslQuery = 'FIND \'' + sanitized + '\' IN NAME FIELDS RETURNING Product2('
            + 'Id, Name, ProductCode, Family, IsActive'
            + ' WHERE IsActive = true';

        if (String.isNotBlank(category)) {
            soslQuery += ' AND Family = \'' + String.escapeSingleQuotes(category) + '\'';
        }
        soslQuery += ' ORDER BY Name ASC LIMIT ' + resultLimit + ')';

        List<List<SObject>> results = Search.query(soslQuery);
        return (List<Product2>) results[0];
    }

    private static List<Product2> searchBySoql(String searchTerm, String category, Integer resultLimit) {
        String pattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        String query = 'SELECT Id, Name, ProductCode, Family, IsActive FROM Product2'
            + ' WHERE IsActive = true'
            + ' AND (Name LIKE :pattern OR ProductCode LIKE :pattern)';

        if (String.isNotBlank(category)) {
            query += ' AND Family = :category';
        }
        query += ' ORDER BY Name ASC LIMIT :resultLimit';

        return Database.query(query);
    }

    public class Input {
        @InvocableVariable(label='Search Term'
            description='Part name, code, or keyword to search for')
        public String searchTerm;

        @InvocableVariable(label='Part Category'
            description='Filter by family/category (e.g. Powertrain, Brakes, Electrical, Body)')
        public String category;

        @InvocableVariable(label='Max Results'
            description='Maximum number of results to return (default 5)')
        public Integer maxResults;
    }

    public class Output {
        @InvocableVariable(label='Parts Found' description='True if matching parts were found')
        public Boolean partsFound;

        @InvocableVariable(label='Part Id' description='Salesforce ID of the best matching part')
        public String partId;

        @InvocableVariable(label='Part Name' description='Display name of the part')
        public String partName;

        @InvocableVariable(label='Part Code' description='Product code of the part')
        public String partCode;

        @InvocableVariable(label='Part Family' description='Category/family of the part')
        public String partFamily;

        @InvocableVariable(label='Unit Price' description='Standard unit price of the part')
        public Decimal unitPrice;

        @InvocableVariable(label='Results Summary'
            description='Formatted list of all matching parts with codes and prices')
        public String resultsSummary;

        @InvocableVariable(label='Total Matches' description='Total number of matching parts found')
        public Integer totalMatches;

        @InvocableVariable(label='Message' description='Status message or error details')
        public String message;
    }
}