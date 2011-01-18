module OpenGov
  class Contributions < Resources
    
    # This value for transaction_namespace= in TD API cals limits our queries with TransparencyData to the NIMSP dataset.
    IMSP_NAMESPACE = 'urn:nimsp:recipient'
    
    def self.import!
      puts "Deleting existing contributions.."

      Contribution.delete_all

      Person.with_transparencydata_id.each do |person|
        puts "Importing contributions for #{person.full_name}"
        total = 0

        begin
          entity = GovKit::TransparencyData::Entity.find_by_id(person.transparencydata_id)
          entity.external_ids.each do |eid|
            page = 0
            contributions = []

            # Fetch the NIMSP external ids only.
            # puts "fetching '#{eid[:namespace]}' '#{eid[:id]}'"
            if eid[:namespace].eql?(IMSP_NAMESPACE)
              # Loop to get all contributions
              begin
                page += 1
                begin
                  contributions = GovKit::TransparencyData::Contribution.find(:recipient_ext_id => eid[:id], :page => page)

                  contributions.each do |contribution|
                    make_contribution(person, contribution)
                  end
                  # process them.
                rescue Crack::ParseError => e
                  puts e.class.to_s + ": Invalid JSON for person " + person.transparencydata_id
                  break
                rescue GovKit::ResourceNotFound => e
                  puts "Got resource not found."
                  break
                end
                total += contributions.size
              end while contributions.size > 0
            end

          end
        end

        puts "Fetched #{total} contributions from TransparencyData"
      end
    end

    def self.make_contribution(person, con)
      begin
        contribution = Contribution.create(
          :person_id => person.id,
          :state_id => person.state_id,
          :industry_id => con.contributor_category,
          :contributor_state_id => con.contributor_state.blank? ? nil : State.find_by_abbrev(con.contributor_state).try(:id),
          :contributor_occupation => con.contributor_occupation,
          :contributor_employer => con.contributor_employer,
          :amount => con.amount,
          :date => Date.valid_date!(con.date),
          :contributor_city => con.contributor_city,
          :contributor_name => con.contributor_name,
          :contributor_zipcode => con.contributor_zipcode,
          :transparencydata_id => con.transaction_id
        )
      rescue ActiveRecord::InvalidForeignKey => e
        puts "Could not find contributor category with code #{con.contributor_category} on transaction #{con.transaction_id}; skipping."
      end
    end
  end
end
