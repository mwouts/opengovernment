module OpenGov
  class Bills < Resources
    VOTES_DIR = File.join(FIFTYSTATES_DIR, "api", "votes")

    @people = {}

    class << self
      def build_people_hash
        # Cache all of the ids of people so we don't have to keep looking them up.
        Person.all(:conditions => "fiftystates_id is not null").each do |p|
          @people[p.fiftystates_id] = p.id
        end
      end

      def fetch
        FileUtils.mkdir_p(FIFTYSTATES_DIR)
        Dir.chdir(FIFTYSTATES_DIR)
        
        State.loadable.each do |state|
          fiftystates_fn = "#{state.abbrev.downcase}.zip"
          curl_ops = File.exists?(fiftystates_fn) ? "-z #{fiftystates_fn}" : ''

          puts "---------- Downloading the bills for #{state.name}"
          `curl #{curl_ops} -fO http://fiftystates-dev.sunlightlabs.com/data/#{fiftystates_fn}`
          `unzip -u #{fiftystates_fn}`
        end
      end

      # TODO: The :remote => false option only applies to the intial import.
      # after that, we always want to use import_state(state)
      def import!(options = {})
        build_people_hash

        State.loadable.each do |state|
          if options[:remote]
            import_state(state)
          else
            state_dir = File.join(FIFTYSTATES_DIR, "api", state.abbrev.downcase)

            unless File.exists?(state_dir)
              puts "Local Open State API data for #{state.name} is missing."
              return import!(:remote => true)
            end

            puts "\nLoading local Open State data for #{state.name}."
            state.sessions.each do |session|
              [GovKit::FiftyStates::CHAMBER_LOWER, GovKit::FiftyStates::CHAMBER_UPPER].each do |house|
                bills_dir = File.join(state_dir, session.name, house, "bills")
                all_bills = File.join(bills_dir, "*")
                Dir.glob(all_bills).each_with_index do |file, i|
                  if i % 10 == 0
                    print '.'
                    $stdout.flush
                  end

                  bill = GovKit::FiftyStates::Bill.parse(JSON.parse(File.read(file)))
                  import_bill(bill, state, options)
                end
              end
            end
          end
        end
      end

      def import_state(state)
        puts "\nUpdating Open State bill data for #{state.name} from remote API"

        # TODO: This isn't quite right...
        bills = GovKit::FiftyStates::Bill.latest(Bill.maximum(:updated_at).to_date, state.abbrev.downcase)

        if bills.empty?
          puts "No bills found \n"
        else
          bills.each_with_index do |bill, i|
            if i % 10 == 0
              print '.'
              $stdout.flush
            end
            import_bill(bill, state, {})
          end
        end
      end

      def import_bill(bill, state, options)
        Bill.transaction do
          # A bill number alone does not identify a bill; we also need a session ID.
          session = state.legislature.sessions.find_by_name(bill.session)

          @bill = Bill.find_or_initialize_by_bill_number_and_session_id(bill.bill_id, session.id)
          @bill.title = bill.title
          @bill.fiftystates_id = bill["_id"]
          @bill.state = state
          @bill.chamber = state.legislature.instance_eval("#{bill.chamber}_chamber")

          # There is no unique data on a bill's actions that we can key off of, so we
          # must delete and recreate them all each time.
          if @bill.id
            @bill.actions.delete_all
            @bill.sponsors.delete_all
            @bill.versions.delete_all
            @bill.votes.destroy_all
            @bill.subjects.destroy_all
          end

          bill.actions.each do |action|
            @bill.actions << Action.new(
              :actor => action.actor,
              :action => action.action,
              :kind => action[:type] && action[:type].first,
              :action_number => action[:action_number],
              :date => Date.valid_date!(action.date))
          end

          bill.versions.each do |version|
            v = Version.find_or_initialize_by_bill_id_and_name(@bill.id, version.name)
            v.url = version.url
            v.save!
          end

          # Same deal as with actions, above
          bill.sponsors.each do |sponsor|
            Sponsorship.create(
              :bill => @bill,
              :sponsor_id => @people[sponsor.leg_id],
              :kind => sponsor[:type]
            )
          end

          if bill.subjects?
            bill.subjects.each do |subject|
              @bill.subjects.create(:name => subject)
            end
          end

          bill.votes.each do |vote|
            v = @bill.votes.create(
              :yes_count => vote.yes_count,
              :no_count => vote.no_count,
              :other_count => vote.other_count,
              :passed => vote.passed,
              :date => Date.valid_date!(vote.date),
              :motion => vote.motion,
              :chamber => state.legislature.instance_eval("#{vote.chamber}_chamber")
            )

            ['yes', 'no', 'other'].each do |vote_type|
              vote["#{vote_type}_votes"] && vote["#{vote_type}_votes"].each do |rcall|
                v.roll_calls.create(:vote_type => vote_type, :person => Person.find_by_fiftystates_id(rcall.leg_id.to_s)) if rcall.leg_id
              end
            end
          end

          unless @bill.save!
            puts "Skipping...#{@bill.errors.full_messages.join(',')}"
          end
        end # transaction
      end
    end
  end
end