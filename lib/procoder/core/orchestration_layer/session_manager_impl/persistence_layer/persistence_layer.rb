# frozen_string_literal: true

module Procoder
  module Core
    module OrchestrationLayer
      module SessionManagerImpl
        # The PersistenceLayer handles the storage and retrieval of session data.
        # It abstracts the underlying storage mechanism from the SessionManager.
        class PersistenceLayer
          def initialize(storage_adapter)
            @storage_adapter = storage_adapter
          end

          def save(session_id, data)
            @storage_adapter.write(session_id, data)
          end

          def load(session_id)
            @storage_adapter.read(session_id)
          end

          def delete(session_id)
            @storage_adapter.delete(session_id)
          end

          def exists?(session_id)
            @storage_adapter.exists?(session_id)
          end
        end
      end
    end
  end
end
