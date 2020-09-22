-- | Kafka specific functions
module Network.Flink.Kafka (kafkaRecord) where

import Data.ProtoLens (Message, defMessage, encodeMessage)
import Data.Text (Text)
import Lens.Family2 ((&), (.~))
import qualified Proto.Kafka as Kafka
import qualified Proto.Kafka_Fields as Kafka

-- | Takes a `topic`, `key`, and protobuf `value` to construct 'KafkaProducerRecord's for egress
kafkaRecord ::
  (Message v) =>
  -- | Kafka topic
  Text ->
  -- | Kafka key
  Text ->
  -- | Kafka value
  v ->
  Kafka.KafkaProducerRecord
kafkaRecord topic k v =
  defMessage
    & Kafka.topic .~ topic
    & Kafka.key .~ k
    & Kafka.valueBytes .~ encodeMessage v