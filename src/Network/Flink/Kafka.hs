-- | Kafka specific functions
module Network.Flink.Kafka (kafkaRecord) where

import Data.ProtoLens (defMessage)
import Data.Text (Text)
import Lens.Family2 ((&), (.~))
import qualified Proto.Kafka as Kafka
import qualified Proto.Kafka_Fields as Kafka
import Data.ByteString (ByteString)

-- | Takes a `topic`, `key`, and `value` to construct 'KafkaProducerRecord's for egress
kafkaRecord ::
  -- | Kafka topic
  Text ->
  -- | Kafka key
  Text ->
  -- | Kafka value
  ByteString ->
  Kafka.KafkaProducerRecord
kafkaRecord topic k v =
  defMessage
    & Kafka.topic .~ topic
    & Kafka.key .~ k
    & Kafka.valueBytes .~ v