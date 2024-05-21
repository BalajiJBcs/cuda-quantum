/*******************************************************************************
 * Copyright (c) 2022 - 2024 NVIDIA Corporation & Affiliates.                  *
 * All rights reserved.                                                        *
 *                                                                             *
 * This source code and the accompanying materials are made available under    *
 * the terms of the Apache License 2.0 which accompanies this distribution.    *
 ******************************************************************************/

#include "CodeGenOps.h"
#include "PassDetails.h"
#include "cudaq/Optimizer/Builder/Intrinsics.h"
#include "cudaq/Optimizer/CodeGen/CCToLLVM.h"
#include "cudaq/Optimizer/CodeGen/Passes.h"
#include "cudaq/Optimizer/CodeGen/Peephole.h"
#include "cudaq/Optimizer/CodeGen/QIRFunctionNames.h"
#include "cudaq/Optimizer/CodeGen/QuakeToLLVM.h"
#include "cudaq/Optimizer/Dialect/CC/CCOps.h"
#include "cudaq/Optimizer/Dialect/Quake/QuakeOps.h"
#include "llvm/ADT/Hashing.h"
#include "llvm/ADT/TypeSwitch.h"
#include "llvm/Support/FormatVariadic.h"
#include "mlir/Conversion/AffineToStandard/AffineToStandard.h"
#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ComplexToLLVM/ComplexToLLVM.h"
#include "mlir/Conversion/ComplexToLibm/ComplexToLibm.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/Pattern.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/MathToLLVM/MathToLLVM.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Dialect/Arith/Transforms/Passes.h"
#include "mlir/Target/LLVMIR/ModuleTranslation.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#define DEBUG_TYPE "convert-to-qir"

using namespace mlir;

namespace {
//===----------------------------------------------------------------------===//
// Code generation: converts the Quake IR to QIR.
//===----------------------------------------------------------------------===//

namespace {
/// Convert Quake dialect to LLVM-IR and QIR.
class ConvertToQIR : public cudaq::opt::impl::ConvertToQIRBase<ConvertToQIR> {
public:
  using ConvertToQIRBase::ConvertToQIRBase;

  /// Measurement counter for unnamed measurements. Resets every module.
  unsigned measureCounter = 0;

  // This is an ad hox transformation to convert constant array values into a
  // buffer of constants.
  LogicalResult eraseConstantArrayOps() {
    bool ok = true;
    getOperation().walk([&](cudaq::cc::ConstantArrayOp carr) {
      // If there is a constant array, then we expect that it is involved in
      // a stdvec initializer expression. So look for the pattern and expand
      // the store into a series of scalar stores.
      //
      //   %100 = cc.const_array [c1, c2, ... cN] : ...
      //   %110 = cc.alloca ...
      //   cc.store %100, %110 : ...
      //   __________________________
      //
      //   cc.store c1, %110[0]
      //   cc.store c2, %110[1]
      //   ...
      //   cc.store cN, %110[N-1]

      // Are all uses the value to a store?
      if (!std::all_of(carr->getUsers().begin(), carr->getUsers().end(),
                       [&](auto *op) {
                         auto st = dyn_cast<cudaq::cc::StoreOp>(op);
                         return st && st.getValue() == carr.getResult();
                       })) {
        ok = false;
        return;
      }

      auto eleTy = cast<cudaq::cc::ArrayType>(carr.getType()).getElementType();
      auto ptrTy = cudaq::cc::PointerType::get(eleTy);
      auto loc = carr.getLoc();
      for (auto *user : carr->getUsers()) {
        auto origStore = cast<cudaq::cc::StoreOp>(user);
        OpBuilder builder(origStore);
        auto buffer = origStore.getPtrvalue();
        for (auto iter : llvm::enumerate(carr.getConstantValues())) {
          auto v = [&]() -> Value {
            auto val = iter.value();
            if (auto fTy = dyn_cast<FloatType>(eleTy))
              return builder.create<arith::ConstantFloatOp>(
                  loc, cast<FloatAttr>(val).getValue(), fTy);
            auto iTy = cast<IntegerType>(eleTy);
            return builder.create<arith::ConstantIntOp>(
                loc, cast<IntegerAttr>(val).getInt(), iTy);
          }();
          std::int32_t idx = iter.index();
          Value arrWithOffset = builder.create<cudaq::cc::ComputePtrOp>(
              loc, ptrTy, buffer, ArrayRef<cudaq::cc::ComputePtrArg>{idx});
          builder.create<cudaq::cc::StoreOp>(loc, v, arrWithOffset);
        }
        origStore.erase();
      }

      carr.erase();
    });
    return ok ? success() : failure();
  }

  /// Greedy pass to match subgraphs in the IR and replace them with codegen
  /// ops. This step makes converting a DAG of nodes in the conversion step
  /// simpler.
  void fuseSubgraphPatterns() {
#if 0
    auto *ctx = &getContext();
    RewritePatternSet patterns(ctx);
    // TODO: Patterns to be added.
    patterns.insert<...>(ctx);
    if (failed(applyPatternsAndFoldGreedily(getModule(), std::move(patterns))))
      signalPassFailure();
#endif
  }

  void runOnOperation() override final {
    fuseSubgraphPatterns();

    auto *context = &getContext();
    if (failed(fuseSubgraphPatterns(context, getOperation()))) {
      signalPassFailure();
      return;
    }
    // Ad hoc deal with ConstantArrayOp transformation.
    // TODO: Merge this into the codegen dialect once that gets to main.
    if (failed(eraseConstantArrayOps())) {
      getOperation().emitOpError("unexpected constant arrays");
      signalPassFailure();
      return;
    }

    LLVMConversionTarget target{*context};
    LLVMTypeConverter typeConverter(&getContext());
    cudaq::opt::initializeTypeConversions(typeConverter);
    RewritePatternSet patterns(context);

    populateComplexToLibmConversionPatterns(patterns, 1);
    populateComplexToLLVMConversionPatterns(typeConverter, patterns);

    populateAffineToStdConversionPatterns(patterns);
    arith::populateCeilFloorDivExpandOpsPatterns(patterns);
    arith::populateArithToLLVMConversionPatterns(typeConverter, patterns);
    populateMathToLLVMConversionPatterns(typeConverter, patterns);

    populateSCFToControlFlowConversionPatterns(patterns);
    cf::populateControlFlowToLLVMConversionPatterns(typeConverter, patterns);
    populateFuncToLLVMConversionPatterns(typeConverter, patterns);
    cudaq::opt::populateCCToLLVMPatterns(typeConverter, patterns);
    cudaq::opt::populateQuakeToLLVMPatterns(typeConverter, patterns,
                                            measureCounter);
    target.addLegalDialect<LLVM::LLVMDialect>();
    target.addLegalOp<ModuleOp>();

    if (failed(
            applyFullConversion(getOperation(), target, std::move(patterns)))) {
      LLVM_DEBUG(getOperation().dump());
      signalPassFailure();
    }
  }
};

} // namespace

LLVM::LLVMStructType cudaq::opt::lambdaAsPairOfPointers(MLIRContext *context) {
  auto ptrTy = cudaq::opt::factory::getPointerType(context);
  SmallVector<Type> pairOfPointers = {ptrTy, ptrTy};
  return LLVM::LLVMStructType::getLiteral(context, pairOfPointers);
}

void cudaq::opt::initializeTypeConversions(LLVMTypeConverter &typeConverter) {
  typeConverter.addConversion(
      [](quake::VeqType type) { return getArrayType(type.getContext()); });
  typeConverter.addConversion(
      [](quake::RefType type) { return getQubitType(type.getContext()); });
  typeConverter.addConversion(
      [](cc::StateType type) { return factory::stateImplType(type); });
  typeConverter.addConversion([](cc::CallableType type) {
    return lambdaAsPairOfPointers(type.getContext());
  });
  typeConverter.addConversion([&typeConverter](cc::SpanLikeType type) {
    auto eleTy = typeConverter.convertType(type.getElementType());
    return factory::stdVectorImplType(eleTy);
  });
  typeConverter.addConversion([](quake::MeasureType type) {
    return IntegerType::get(type.getContext(), 1);
  });
  typeConverter.addConversion([&typeConverter](cc::PointerType type) {
    auto eleTy = type.getElementType();
    if (isa<NoneType>(eleTy))
      return factory::getPointerType(type.getContext());
    eleTy = typeConverter.convertType(eleTy);
    if (isa<NoneType>(eleTy))
      return factory::getPointerType(type.getContext());

    if (auto arrTy = dyn_cast<cc::ArrayType>(eleTy)) {
      // If array has a static size, it becomes an LLVMArrayType.
      assert(arrTy.isUnknownSize());
      return factory::getPointerType(
          typeConverter.convertType(arrTy.getElementType()));
    }
    return factory::getPointerType(eleTy);
  });
  typeConverter.addConversion([&typeConverter](cc::ArrayType type) -> Type {
    auto eleTy = typeConverter.convertType(type.getElementType());
    if (type.isUnknownSize())
      return type;
    return LLVM::LLVMArrayType::get(eleTy, type.getSize());
  });
  typeConverter.addConversion([&typeConverter](cc::StructType type) -> Type {
    SmallVector<Type> members;
    for (auto t : type.getMembers())
      members.push_back(typeConverter.convertType(t));
    return LLVM::LLVMStructType::getLiteral(type.getContext(), members,
                                            type.getPacked());
  });
}

namespace {
class LowerToCG : public cudaq::opt::impl::LowerToCGBase<LowerToCG> {
public:
  using LowerToCGBase::LowerToCGBase;

  void runOnOperation() override {
    if (failed(fuseSubgraphPatterns(&getContext(), getOperation())))
      signalPassFailure();
  }
};
} // namespace
