/** @file
  This file contains definitions required for creation of TGL
  end-to-end check-the-checker test result hob.

@copyright
  INTEL CONFIDENTIAL Copyright 2020 Intel Corporation.

  The source code contained or described herein and all documents related to the
  source code ("Material") are owned by Intel Corporation or its suppliers or
  licensors. Title to the Material remains with Intel Corporation or its suppliers
  and licensors. The Material may contain trade secrets and proprietary and
  confidential information of Intel Corporation and its suppliers and licensors,
  and is protected by worldwide copyright and trade secret laws and treaty
  provisions. No part of the Material may be used, copied, reproduced, modified,
  published, uploaded, posted, transmitted, distributed, or disclosed in any way
  without Intel's prior express written permission.

  No license under any patent, copyright, trade secret or other intellectual
  property right is granted to or conferred upon you by disclosure or delivery
  of the Materials, either expressly, by implication, inducement, estoppel or
  otherwise. Any license under such intellectual property rights must be
  express and approved by Intel in writing.

  Unless otherwise agreed by Intel in writing, you may not remove or alter
  this notice or any other notice embedded in Materials by Intel or
  Intel's suppliers or licensors in any way.

  This file contains an 'Intel Peripheral Driver' and is uniquely identified as
  "Intel Reference Module" and is licensed for Intel CPUs and chipsets under
  the terms of your license agreement with Intel or your vendor. This file may
  be modified by the user, subject to additional terms of the license agreement.

@par Specification Reference:
**/
#ifndef _FUSA_INFO_HOB_H_
#define _FUSA_INFO_HOB_H_

#pragma pack (push, 1)

extern EFI_GUID gSiFusaInfoGuid;

/**
  FuSa Info HOB version
  Use this to compare to the HOB retrieved from the FSP for the
  exact match
**/
#define FUSA_INFO_VERSION 0x00000100

/** Constants used for FUSA_TEST_RESULT->CheckResults[] and
 *  FUSA_TEST_RESULT->TestResult */
/**@defgroup ResultConstant Check Result Constants*/
/**@{*/
#define FUSA_TEST_DEVICE_NOTAVAILABLE  0xFF    /**<device is not available*/
#define FUSA_TEST_NOTRUN               0x0U    /**<check is not run*/
#define FUSA_TEST_FAIL                 0xD2U   /**<check fail*/
#define FUSA_TEST_PASS                 0x2DU   /**<check pass*/
/**@}*/

/** Fusa test result structure
 **/
typedef struct
{
  UINT32 TestNumber;            /**< test number assigned to this test */
  UINT32 TotalChecks;           /**< total number of checks in this test */
  UINT8  TestResult;            /**< if all tests passed then this is FUSA_TEST_PASS.
                                  if at least one check fails, then this is TEST_FAIL
                                  if the device (eg. MC channel DIMM) is not available
                                  then this is FUSA_TEST_DEVICE_NOTAVAILABLE.
                                  if the test has not been run, then this is FUSA_TEST_NOTRUN*/
  UINT8  ReservedByte[3];       /**< reserved, as padding for 4 byte-alignment */
  UINT8  CheckResults[32];      /**< test result for each check.*/
  UINT32 Crc32;                 /**< crc32 of the structure */
} FUSA_TEST_RESULT;


/**
  Fusa Test Number assigned to each Fusa test.
  This will be used for the unique id for each test.
  FUSA_TEST_RESULT->TestNumber will have this value.

  @note While the core4-7 (cbo4-7) that are strictly related to
        the TGL-H are listed, there are not within the
        implementation scope and validation scope yet.
**/
typedef enum
{
  FusaTestNumMc0Cmi = 0,          ///<Check MC0 CMI path, valid if there is DIMM using MC0
  FusaTestNumMc1Cmi,              ///<Check MC1 CMI path, valid if there is DIMM using MC1
  FusaTestNumMc0CmiCh0Data,       ///<Check MC0 CH0 CMI path, valid if there is DIMM using MC0 CH0
  FusaTestNumMc0CmiCh1Data,       ///<Check MC0 CH1 CMI path, valid if there is DIMM using MC0 CH1
  FusaTestNumMc0CmiCh2Data,       ///<Check MC0 CH2 CMI path, valid if there is DIMM using MC0 CH2
  FusaTestNumMc0CmiCh3Data,       ///<Check MC0 CH3 CMI path, valid if there is DIMM using MC0 CH3
  FusaTestNumMc1CmiCh0Data,       ///<Check MC1 CH0 CMI path, valid if there is DIMM using MC1 CH0
  FusaTestNumMc1CmiCh1Data,       ///<Check MC1 CH1 CMI path, valid if there is DIMM using MC1 CH1
  FusaTestNumMc1CmiCh2Data,       ///<Check MC1 CH2 CMI path, valid if there is DIMM using MC1 CH2
  FusaTestNumMc1CmiCh3Data,       ///<Check MC1 CH3 CMI path, valid if there is DIMM using MC1 CH3
  FusaTestNumIbecc0Cmi,           ///<Check Ibecc0 CMI path, valid if there is IBECC range covering MC0 DIMMs
  FusaTestNumIbecc1Cmi,           ///<Check Ibecc1 CMI path, valid if there is IBECC range covering MC1 DIMMs
  FusaTestNumIbecc0EccCorrError,  ///<Check Ibecc0 ECC correctable error, valid if there is IBECC range covering MC0 DIMMs
  FusaTestNumIbecc1EccCorrError,  ///<Check Ibecc1 ECC correctable error, valid if there is IBECC range covering MC1 DIMMs
  FusaTestNumIbecc0EccUncorrError,///<Check Ibecc0 ECC uncorrectable error, valid if there is IBECC range covering MC0 DIMMs
  FusaTestNumIbecc1EccUncorrError,///<Check Ibecc0 ECC uncorrectable error, valid if there is IBECC range covering MC1 DIMMs

  FusaTestNumMc0Mbist,            ///<Check MC0 MBIST
  FusaTestNumMc1Mbist,            ///<Check MC1 MBIST
  FusaTestNumMc0Ch0Mbist,         ///<Check MC0 CH0 MBIST
  FusaTestNumMc0Ch1Mbist,         ///<Check MC0 CH1 MBIST
  FusaTestNumMc0Ch2Mbist,         ///<Check MC0 CH2 MBIST
  FusaTestNumMc0Ch3Mbist,         ///<Check MC0 CH3 MBIST
  FusaTestNumMc1Ch0Mbist,         ///<Check MC1 CH0 MBIST
  FusaTestNumMc1Ch1Mbist,         ///<Check MC1 CH1 MBIST
  FusaTestNumMc1Ch2Mbist,         ///<Check MC1 CH2 MBIST
  FusaTestNumMc1Ch3Mbist,         ///<Check MC1 CH3 MBIST
  FusaTestNumIbecc0Mbist,         ///<Check Ibecc0 MBIST
  FusaTestNumIbecc1Mbist,         ///<Check Ibecc1 MBIST

  FusaTestNumCpu0Idi,             ///<Check core0 IDI path, valid if there is core0 in the SKU
  FusaTestNumCpu1Idi,             ///<Check core1 IDI path, valid if there is core1 in the SKU
  FusaTestNumCpu2Idi,             ///<Check core2 IDI path, valid if there is core2 in the SKU
  FusaTestNumCpu3Idi,             ///<Check core3 IDI path, valid if there is core3 in the SKU
  FusaTestNumCpu4Idi,             ///<Check core4 IDI path, valid if there is core4 in the SKU
  FusaTestNumCpu5Idi,             ///<Check core5 IDI path, valid if there is core5 in the SKU
  FusaTestNumCpu6Idi,             ///<Check core6 IDI path, valid if there is core6 in the SKU
  FusaTestNumCpu7Idi,             ///<Check core7 IDI path, valid if there is core7 in the SKU

  FusaTestNumCpu0Mbist,             ///<Check core0 Mbist, valid if there is core0 in the SKU
  FusaTestNumCpu1Mbist,             ///<Check core1 Mbist, valid if there is core1 in the SKU
  FusaTestNumCpu2Mbist,             ///<Check core2 Mbist, valid if there is core2 in the SKU
  FusaTestNumCpu3Mbist,             ///<Check core3 Mbist, valid if there is core3 in the SKU
  FusaTestNumCpu4Mbist,             ///<Check core4 Mbist, valid if there is core4 in the SKU
  FusaTestNumCpu5Mbist,             ///<Check core5 Mbist, valid if there is core5 in the SKU
  FusaTestNumCpu6Mbist,             ///<Check core6 Mbist, valid if there is core6 in the SKU
  FusaTestNumCpu7Mbist,             ///<Check core7 Mbist, valid if there is core7 in the SKU

  FusaTestNumCboSlice0Ingress,    ///<Check CBO0 ingress path, valid if there is core0 in the SKU
  FusaTestNumCboSlice1Ingress,    ///<Check CBO1 ingress path, valid if there is core1 in the SKU
  FusaTestNumCboSlice2Ingress,    ///<Check CBO2 ingress path, valid if there is core2 in the SKU
  FusaTestNumCboSlice3Ingress,    ///<Check CBO3 ingress path, valid if there is core3 in the SKU
  FusaTestNumCboSlice4Ingress,    ///<Check CBO4 ingress path, valid if there is core4 in the SKU
  FusaTestNumCboSlice5Ingress,    ///<Check CBO5 ingress path, valid if there is core5 in the SKU
  FusaTestNumCboSlice6Ingress,    ///<Check CBO6 ingress path, valid if there is core6 in the SKU
  FusaTestNumCboSlice7Ingress,    ///<Check CBO7 ingress path, valid if there is core7 in the SKU

  FusaTestNumOpiLinkIosfData,     ///<Check OPI Link path
  FusaTestNumDip,                 ///<Check DIP path
  FusaTestNumIop,                 ///<Check IOP path

  FusaTestNumTotal                ///<Totak CTC groups count
} FUSA_TEST_NUMBER;

/**
  Fusa test result HOB structure
**/
typedef struct {
  UINT32 Version;
  FUSA_TEST_RESULT FspDxCtcTestResult[FusaTestNumTotal];
} FUSA_INFO_HOB;

#pragma pack (pop)

#endif // _FUSA_INFO_HOB_H_
