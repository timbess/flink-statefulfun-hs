module Network.Flink.Internal.ProtoServant where

import qualified Data.ByteString.Lazy as BS
import qualified Data.List.NonEmpty as NE
import qualified Data.ProtoLens as P
import Network.HTTP.Media ((//))
import qualified Servant.API.ContentTypes as S

data Proto

instance S.Accept Proto where
  contentTypes _ =
    NE.fromList
      [ "application" // "octet-stream",
        "application" // "protobuf",
        "application" // "x-protobuf",
        "application" // "vnd.google.protobuf"
      ]

instance P.Message m => S.MimeRender Proto m where
  mimeRender _ = BS.fromStrict . P.encodeMessage

instance P.Message m => S.MimeUnrender Proto m where
  mimeUnrender _ = P.decodeMessage . BS.toStrict