{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Torch.NN where

import Control.Applicative (Applicative (liftA2))
import Control.Monad.State.Strict
import Data.Foldable (toList)
import Data.Kind
import GHC.Generics
import System.IO.Unsafe (unsafePerformIO)
import Torch.Autograd
import Torch.Device
import Torch.Functional
import Torch.Initializers
import Torch.Internal.Cast (cast3)
import qualified Torch.Internal.Managed.Native as ATen
import qualified Torch.Internal.Managed.Type.Tensor as ATen
import Torch.Scalar
import Torch.Tensor
import Torch.TensorFactories (ones', randIO', randnIO', zeros')

type Parameter = IndependentTensor

type ParamStream a = State [Parameter] a

nextParameter :: ParamStream Parameter
nextParameter = do
  params <- get
  case params of
    [] -> error "Not enough parameters supplied to replaceParameters"
    (p : t) -> do put t; return p

class HasForward f a b | f a -> b where
  forward :: f -> a -> b
  default forward ::
    ( Generic f,
      Generic a,
      Generic b,
      GHasForward (Rep f) (Rep a) (Rep b)
    ) =>
    f ->
    a ->
    b
  forward f a = to $ gForward (from f) (from a)
  forwardStoch :: f -> a -> IO b
  default forwardStoch ::
    ( Generic f,
      Generic a,
      Generic b,
      GHasForward (Rep f) (Rep a) (Rep b)
    ) =>
    f ->
    a ->
    IO b
  forwardStoch f a = to <$> gForwardStoch (from f) (from a)

class GHasForward (f :: Type -> Type) (a :: Type -> Type) (b :: Type -> Type) | f a -> b where
  gForward :: forall c c' c''. f c -> a c' -> b c''
  gForwardStoch :: forall c c' c''. f c -> a c' -> IO (b c)

instance GHasForward U1 U1 U1 where
  gForward U1 U1 = U1
  gForwardStoch U1 U1 = return U1

instance
  ( GHasForward f a b,
    GHasForward g a' b',
    b'' ~ (b :+: b')
  ) =>
  GHasForward (f :+: g) (a :+: a') b''
  where
  gForward (L1 f) (L1 a) = L1 $ gForward f a
  gForward (R1 g) (R1 a') = R1 $ gForward g a'
  gForwardStoch (L1 f) (L1 a) = L1 <$> gForwardStoch f a
  gForwardStoch (R1 g) (R1 a') = R1 <$> gForwardStoch g a'

instance
  ( GHasForward f a b,
    GHasForward g a' b',
    b'' ~ (b :*: b')
  ) =>
  GHasForward (f :*: g) (a :*: a') b''
  where
  gForward (f :*: g) (a :*: a') = gForward f a :*: gForward g a'
  gForwardStoch (f :*: g) (a :*: a') = liftA2 (:*:) (gForwardStoch f a) (gForwardStoch g a')

instance
  (HasForward f a b) =>
  GHasForward (K1 i f) (K1 i a) (K1 i b)
  where
  gForward (K1 f) (K1 a) = K1 $ forward f a
  gForwardStoch (K1 f) (K1 a) = K1 <$> forwardStoch f a

instance
  (GHasForward f a b) =>
  GHasForward (M1 i t f) (M1 i t' a) (M1 i t' b)
  where
  gForward (M1 f) (M1 a) = M1 $ gForward f a
  gForwardStoch (M1 f) (M1 a) = M1 <$> gForwardStoch f a

class Parameterized f where
  flattenParameters :: f -> [Parameter]
  default flattenParameters :: (Generic f, GParameterized (Rep f)) => f -> [Parameter]
  flattenParameters f = gFlattenParameters (from f)

  _replaceParameters :: f -> ParamStream f
  default _replaceParameters :: (Generic f, GParameterized (Rep f)) => f -> ParamStream f
  _replaceParameters f = to <$> _gReplaceParameters (from f)

  replaceDevice :: Device -> f -> f
  default replaceDevice :: (Generic f, GParameterized (Rep f)) => Device -> f -> f
  replaceDevice dev f = to $ gReplaceDevice dev (from f)

defaultReplaceDevice :: Parameterized a => Device -> a -> a
defaultReplaceDevice dev f = replaceParameters f $ map (IndependentTensor . (_toDevice dev) . toDependent) $ flattenParameters f

replaceParameters :: Parameterized f => f -> [Parameter] -> f
replaceParameters f params =
  let (f', remaining) = runState (_replaceParameters f) params
   in if null remaining
        then f'
        else error "Some parameters in a call to replaceParameters haven't been consumed!"

instance Parameterized a => ToDevice a where
  toDevice = replaceDevice

instance Parameterized Tensor where
  flattenParameters _ = []
  _replaceParameters = return
  replaceDevice = _toDevice

instance Parameterized Parameter where
  flattenParameters = pure
  _replaceParameters _ = nextParameter
  replaceDevice device t = IndependentTensor $ (_toDevice device) $ toDependent t

instance {-# OVERLAPS #-} (Scalar a) => Parameterized a where
  flattenParameters _ = []
  _replaceParameters = return
  replaceDevice _ = id

instance {-# OVERLAPS #-} (Parameterized a, Parameterized b) => Parameterized (a, b) where
  flattenParameters (a, b) = flattenParameters a ++ flattenParameters b
  _replaceParameters (a, b) = do
    a' <- _replaceParameters a
    b' <- _replaceParameters b
    return (a', b')
  replaceDevice dev (a, b) = (replaceDevice dev a, replaceDevice dev b)

instance {-# OVERLAPS #-} (Parameterized a, Parameterized b, Parameterized c) => Parameterized (a, b, c) where
  flattenParameters (a, b, c) = flattenParameters a ++ flattenParameters b ++ flattenParameters c
  _replaceParameters (a, b, c) = do
    a' <- _replaceParameters a
    b' <- _replaceParameters b
    c' <- _replaceParameters c
    return (a', b', c')
  replaceDevice dev (a, b, c) = (replaceDevice dev a, replaceDevice dev b, replaceDevice dev c)

instance {-# OVERLAPS #-} (Foldable t, Traversable t, Parameterized a) => Parameterized (t a) where
  flattenParameters = (=<<) flattenParameters . toList
  _replaceParameters = mapM _replaceParameters
  replaceDevice dev t = fmap (replaceDevice dev) t

instance Parameterized (a -> a) where
  flattenParameters _ = []
  _replaceParameters = return
  replaceDevice _ = id

class GParameterized f where
  gFlattenParameters :: forall a. f a -> [Parameter]
  _gReplaceParameters :: forall a. f a -> ParamStream (f a)
  gReplaceDevice :: forall a. Device -> f a -> f a

instance GParameterized U1 where
  gFlattenParameters U1 = []
  _gReplaceParameters U1 = return U1
  gReplaceDevice dev U1 = U1

instance (GParameterized f, GParameterized g) => GParameterized (f :+: g) where
  gFlattenParameters (L1 x) = gFlattenParameters x
  gFlattenParameters (R1 x) = gFlattenParameters x
  _gReplaceParameters (L1 x) = do
    x' <- _gReplaceParameters x
    return $ L1 x'
  _gReplaceParameters (R1 x) = do
    x' <- _gReplaceParameters x
    return $ R1 x'
  gReplaceDevice dev (L1 x) = L1 (gReplaceDevice dev x)
  gReplaceDevice dev (R1 x) = R1 (gReplaceDevice dev x)

instance (GParameterized f, GParameterized g) => GParameterized (f :*: g) where
  gFlattenParameters (x :*: y) = gFlattenParameters x ++ gFlattenParameters y
  _gReplaceParameters (x :*: y) = do
    x' <- _gReplaceParameters x
    y' <- _gReplaceParameters y
    return $ x' :*: y'
  gReplaceDevice dev (x :*: y) = (gReplaceDevice dev x) :*: (gReplaceDevice dev y)

instance (Parameterized c) => GParameterized (K1 i c) where
  gFlattenParameters (K1 x) = flattenParameters x
  _gReplaceParameters (K1 x) = do
    x' <- _replaceParameters x
    return $ K1 x'
  gReplaceDevice dev (K1 x) = K1 (replaceDevice dev x)

instance (GParameterized f) => GParameterized (M1 i t f) where
  gFlattenParameters (M1 x) = gFlattenParameters x
  _gReplaceParameters (M1 x) = do
    x' <- _gReplaceParameters x
    return $ M1 x'
  gReplaceDevice dev (M1 x) = M1 (gReplaceDevice dev x)

class Randomizable spec f | spec -> f where
  sample :: spec -> IO f

--
-- Linear FC Layer
--

data LinearSpec = LinearSpec
  { in_features :: Int,
    out_features :: Int
  }
  deriving (Show, Eq)

data Linear = Linear
  { weight :: Parameter,
    bias :: Parameter
  }
  deriving (Show, Generic, Parameterized)

linear :: Linear -> Tensor -> Tensor
linear layer input = linear' input w b
  where
    linear' input weight bias = unsafePerformIO $ cast3 ATen.linear_ttt input weight bias
    w = toDependent (weight layer)
    b = toDependent (bias layer)

linearForward :: Linear -> Tensor -> Tensor
linearForward = linear -- temporary alias until dependencies are updated

instance HasForward Linear Tensor Tensor where
  forward = linearForward
  forwardStoch m x = pure $ linearForward m x

instance Randomizable LinearSpec Linear where
  sample LinearSpec {..} = do
    w <-
      makeIndependent
        =<< kaimingUniform
          FanIn
          (LeakyRelu $ Prelude.sqrt (5.0 :: Float))
          [out_features, in_features]
    init <- randIO' [out_features]
    let bound =
          (1 :: Float)
            / Prelude.sqrt
              ( fromIntegral
                  ( getter FanIn $
                      calculateFan
                        [ out_features,
                          in_features
                        ]
                  ) ::
                  Float
              )
    b <-
      makeIndependent
        =<< pure
          ( subScalar bound $ mulScalar (bound * 2.0) init
          )
    return $ Linear w b

--
-- Conv2d
--

data Conv2dSpec = Conv2dSpec
  { inputChannelSize :: Int,
    outputChannelSize :: Int,
    kernelHeight :: Int,
    kernelWidth :: Int
  }
  deriving (Show, Eq)

data Conv2d = Conv2d
  { conv2dWeight :: Parameter,
    conv2dBias :: Parameter
  }
  deriving (Show, Generic, Parameterized)

conv2dForward ::
  -- | layer
  Conv2d ->
  -- | stride
  (Int, Int) ->
  -- | padding
  (Int, Int) ->
  -- | input
  Tensor ->
  -- | output
  Tensor
conv2dForward layer = Torch.Functional.conv2d' w b
  where
    w = toDependent (conv2dWeight layer)
    b = toDependent (conv2dBias layer)

instance Randomizable Conv2dSpec Conv2d where
  sample Conv2dSpec {..} = do
    w <-
      makeIndependent
        =<< kaimingUniform
          FanIn
          (LeakyRelu $ Prelude.sqrt (5.0 :: Float))
          [ outputChannelSize,
            inputChannelSize,
            kernelHeight,
            kernelWidth
          ]
    init <- randIO' [outputChannelSize]
    let bound =
          (1 :: Float)
            / Prelude.sqrt
              ( fromIntegral
                  ( getter FanIn $
                      calculateFan
                        [ outputChannelSize,
                          inputChannelSize,
                          kernelHeight,
                          kernelWidth
                        ]
                  ) ::
                  Float
              )
    b <-
      makeIndependent
        =<< pure
          ( subScalar bound $ mulScalar (bound * 2.0) init
          )
    return $ Conv2d w b

data BatchNormSpec = BatchNormSpec
  { numFeatures :: Int
  }
  deriving (Show, Eq)

data BatchNorm = BatchNorm
  { batchNormWeight :: Parameter,
    batchNormBias :: Parameter,
    runningMean :: Tensor,
    runningVar :: Tensor
  }
  deriving (Show, Generic)

instance Parameterized BatchNorm where
  replaceDevice dev BatchNorm {..} =
    BatchNorm
      (replaceDevice dev batchNormWeight)
      (replaceDevice dev batchNormBias)
      (replaceDevice dev runningMean)
      (replaceDevice dev runningVar)

batchNormForward :: BatchNorm -> Bool -> Double -> Double -> Tensor -> Tensor
batchNormForward BatchNorm {..} train momentum eps input =
  Torch.Functional.batchNorm
    (toDependent batchNormWeight)
    (toDependent batchNormBias)
    runningMean
    runningVar
    train
    momentum
    eps
    input

instance Randomizable BatchNormSpec BatchNorm where
  sample BatchNormSpec {..} = do
    w <- makeIndependent (ones' [numFeatures])
    b <- makeIndependent (zeros' [numFeatures])
    mean <- toDependent <$> makeIndependentWithRequiresGrad (zeros' [numFeatures]) False
    var <- toDependent <$> makeIndependentWithRequiresGrad (ones' [numFeatures]) False
    return $ BatchNorm w b mean var

data UpSampleSpec = UpSampleSpec
  { upsampleInputFilters :: Int,
    upsampleStride :: Int
  }
  deriving (Show, Eq)

instance Parameterized UpSampleSpec where
  flattenParameters _ = []
  _replaceParameters = return
  replaceDevice _ = id

data UpSample = UpSample
  { upsampleSpec :: UpSampleSpec
  }
  deriving (Show, Generic, Parameterized)

instance Randomizable UpSampleSpec UpSample where
  sample s = do
    UpSample
      <$> pure s

instance HasForward UpSample Tensor Tensor where
  forward (UpSample (UpSampleSpec {..})) input =
    upsampleNearest2d (outputWidth * upsampleStride, outputHeight * upsampleStride) (fromIntegral upsampleStride) (fromIntegral upsampleStride) input
    where
      outputWidth : outputHeight : _ = reverse $ shape input
  forwardStoch m x = pure $ forward m x
