/** @file
  Header file for GpioConfig structure used by GPIO library.

 @copyright
  INTEL CONFIDENTIAL
  Copyright 2014 - 2017 Intel Corporation.

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
#ifndef _GPIO_CONFIG_H_
#define _GPIO_CONFIG_H_

#pragma pack(push, 1)

///
/// For any GpioPad usage in code use GPIO_PAD type
///
typedef UINT32 GPIO_PAD;


///
/// For any GpioGroup usage in code use GPIO_GROUP type
///
typedef UINT32 GPIO_GROUP;

/**
  GPIO configuration structure used for pin programming.
  Structure contains fields that can be used to configure pad.
**/
typedef struct {
  /**
  Pad Mode
  Pad can be set as GPIO or one of its native functions.
  When in native mode setting Direction (except Inversion), OutputState,
  InterruptConfig, Host Software Pad Ownership and OutputStateLock are unnecessary.
  Refer to definition of GPIO_PAD_MODE.
  Refer to EDS for each native mode according to the pad.
  **/
  UINT32 PadMode            : 5;
  /**
  Host Software Pad Ownership
  Set pad to ACPI mode or GPIO Driver Mode.
  Refer to definition of GPIO_HOSTSW_OWN.
  **/
  UINT32 HostSoftPadOwn     : 2;
  /**
  GPIO Direction
  Can choose between In, In with inversion, Out, both In and Out, both In with inversion and out or disabling both.
  Refer to definition of GPIO_DIRECTION for supported settings.
  **/
  UINT32 Direction           : 6;
  /**
  Output State
  Set Pad output value.
  Refer to definition of GPIO_OUTPUT_STATE for supported settings.
  This setting takes place when output is enabled.
  **/
  UINT32 OutputState         : 2;
  /**
  GPIO Interrupt Configuration
  Set Pad to cause one of interrupts (IOxAPIC/SCI/SMI/NMI).
  This setting is applicable only if GPIO is in GpioMode with input enabled.
  Refer to definition of GPIO_INT_CONFIG for supported settings.
  **/
  UINT32 InterruptConfig     : 9;
  /**
  GPIO Power Configuration.
  This setting controls Pad Reset Configuration.
  Refer to definition of GPIO_RESET_CONFIG for supported settings.
  **/
  UINT32 PowerConfig        : 8;
  /**
  GPIO Electrical Configuration
  This setting controls pads termination and voltage tolerance.
  Refer to definition of GPIO_ELECTRICAL_CONFIG for supported settings.
  **/
  UINT32 ElectricalConfig   : 9;
  /**
  GPIO Lock Configuration
  This setting controls pads lock.
  Refer to definition of GPIO_LOCK_CONFIG for supported settings.
  **/
  UINT32 LockConfig         : 4;
  /**
  Additional GPIO configuration
  Refer to definition of GPIO_OTHER_CONFIG for supported settings.
  **/
  UINT32 OtherSettings     :  2;
  UINT32 RsvdBits          : 17;    ///< Reserved bits for future extension
} GPIO_CONFIG;


typedef enum {
  GpioHardwareDefault        = 0x0    ///< Leave setting unmodified
} GPIO_HARDWARE_DEFAULT;

/**
  GPIO Pad Mode
  Refer to GPIO documentation on native functions available for certain pad.
  If GPIO is set to one of NativeX modes then following settings are not applicable
  and can be skipped:
  - Interrupt related settings
  - Host Software Ownership
  - Output/Input enabling/disabling
  - Output lock
**/
typedef enum {
  GpioPadModeGpio     = 0x1,
  GpioPadModeNative1  = 0x3,
  GpioPadModeNative2  = 0x5,
  GpioPadModeNative3  = 0x7,
  GpioPadModeNative4  = 0x9
} GPIO_PAD_MODE;

/**
  Host Software Pad Ownership modes
  This setting affects GPIO interrupt status registers. Depending on chosen ownership
  some GPIO Interrupt status register get updated and other masked.
  Please refer to EDS for HOSTSW_OWN register description.
**/
typedef enum {
  GpioHostOwnDefault = 0x0,   ///< Leave ownership value unmodified
  /**
  Set HOST ownership to ACPI.
  Use this setting if pad is not going to be used by GPIO OS driver.
  If GPIO is configured to generate SCI/SMI/NMI then this setting must be
  used for interrupts to work
  **/
  GpioHostOwnAcpi    = 0x1,
  /**
  Set HOST ownership to GPIO Driver mode.
  Use this setting only if GPIO pad should be controlled by GPIO OS Driver.
  GPIO OS Driver will be able to control the pad if appropriate entry in
  ACPI exists (refer to ACPI specification for GpioIo and GpioInt descriptors)
  **/
  GpioHostOwnGpio    = 0x3
} GPIO_HOSTSW_OWN;

///
/// GPIO Direction
///
typedef enum {
  GpioDirDefault         = 0x0,                ///< Leave pad direction setting unmodified
  GpioDirInOut           = (0x1 | (0x1 << 3)), ///< Set pad for both output and input
  GpioDirInInvOut        = (0x1 | (0x3 << 3)), ///< Set pad for both output and input with inversion
  GpioDirIn              = (0x3 | (0x1 << 3)), ///< Set pad for input only
  GpioDirInInv           = (0x3 | (0x3 << 3)), ///< Set pad for input with inversion
  GpioDirOut             = 0x5,                ///< Set pad for output only
  GpioDirNone            = 0x7                 ///< Disable both output and input
} GPIO_DIRECTION;

/**
  GPIO Output State
  This field is relevant only if output is enabled
**/
typedef enum {
  GpioOutDefault         = 0x0,  ///< Leave output value unmodified
  GpioOutLow             = 0x1,  ///< Set output to low
  GpioOutHigh            = 0x3   ///< Set output to high
} GPIO_OUTPUT_STATE;

/**
  GPIO interrupt configuration
  This setting is applicable only if pad is in GPIO mode and has input enabled.
  GPIO_INT_CONFIG allows to choose which interrupt is generated (IOxAPIC/SCI/SMI/NMI)
  and how it is triggered (edge or level). Refer to PADCFG_DW0 register description in
  EDS for details on this settings.
  Field from GpioIntNmi to GpioIntApic can be OR'ed with GpioIntLevel to GpioIntBothEdge
  to describe an interrupt e.g. GpioIntApic | GpioIntLevel
  If GPIO is set to cause an SCI then also GPI_GPE_EN is enabled for this pad.
  If GPIO is set to cause an NMI then also GPI_NMI_EN is enabled for this pad.
  Not all GPIO are capable of generating an SMI or NMI interrupt.
  When routing GPIO to cause an IOxAPIC interrupt care must be taken, as this
  interrupt cannot be shared and its IRQn number is not configurable.
  Refer to EDS for GPIO pads IRQ numbers (PADCFG_DW1.IntSel)
  If GPIO is under GPIO OS driver control and appropriate ACPI GpioInt descriptor
  exist then use only trigger type setting (from GpioIntLevel to GpioIntBothEdge).
  This type of GPIO Driver interrupt doesn't have any additional routing setting
  required to be set by BIOS. Interrupt is handled by GPIO OS Driver.
**/

typedef enum {
  GpioIntDefault           = 0x0,  ///< Leave value of interrupt routing unmodified
  GpioIntDis               = 0x1,  ///< Disable IOxAPIC/SCI/SMI/NMI interrupt generation
  GpioIntNmi               = 0x3,  ///< Enable NMI interrupt only
  GpioIntSmi               = 0x5,  ///< Enable SMI interrupt only
  GpioIntSci               = 0x9,  ///< Enable SCI interrupt only
  GpioIntApic              = 0x11, ///< Enable IOxAPIC interrupt only
  GpioIntLevel       = (0x1 << 5), ///< Set interrupt as level triggered
  GpioIntEdge        = (0x3 << 5), ///< Set interrupt as edge triggered (type of edge depends on input inversion)
  GpioIntLvlEdgDis   = (0x5 << 5), ///< Disable interrupt trigger
  GpioIntBothEdge    = (0x7 << 5)  ///< Set interrupt as both edge triggered
} GPIO_INT_CONFIG;

#define B_GPIO_INT_CONFIG_INT_SOURCE_MASK  0x1F ///< Mask for GPIO_INT_CONFIG for interrupt source
#define B_GPIO_INT_CONFIG_INT_TYPE_MASK    0xE0 ///< Mask for GPIO_INT_CONFIG for interrupt type

/**
  GPIO Power Configuration
  GPIO_RESET_CONFIG allows to set GPIO Reset type (PADCFG_DW0.PadRstCfg) which will
  be used to reset certain GPIO settings.
  Refer to EDS for settings that are controllable by PadRstCfg.
**/
typedef enum {


  GpioResetDefault   = 0x00,        ///< Leave value of pad reset unmodified
  ///
  /// Deprecated settings. Maintained only for compatibility.
  ///
  GpioResetPwrGood   = 0x09,        ///< GPP: RSMRST; GPD: DSW_PWROK; (PadRstCfg = 00b = "Powergood")
  GpioResetDeep      = 0x0B,        ///< Deep GPIO Reset (PadRstCfg = 01b = "Deep GPIO Reset")
  GpioResetNormal    = 0x0D,        ///< GPIO Reset (PadRstCfg = 10b = "GPIO Reset" )
  GpioResetResume    = 0x0F,        ///< GPP: Reserved; GPD: RSMRST; (PadRstCfg = 11b = "Resume Reset" )

  ///
  /// New GPIO reset configuration options
  ///
  /**
  Resume Reset (RSMRST)
    GPP: PadRstCfg = 00b = "Powergood"
    GPD: PadRstCfg = 11b = "Resume Reset"
  Pad setting will reset on:
  - DeepSx transition
  - G3
  Pad settings will not reset on:
  - S3/S4/S5 transition
  - Warm/Cold/Global reset
  **/
  GpioResumeReset      = 0x01,
  /**
  Host Deep Reset
    PadRstCfg = 01b = "Deep GPIO Reset"
  Pad settings will reset on:
  - Warm/Cold/Global reset
  - DeepSx transition
  - G3
  Pad settings will not reset on:
  - S3/S4/S5 transition
  **/
  GpioHostDeepReset    = 0x03,
  /**
  Platform Reset (PLTRST)
    PadRstCfg = 10b = "GPIO Reset"
  Pad settings will reset on:
  - S3/S4/S5 transition
  - Warm/Cold/Global reset
  - DeepSx transition
  - G3
  **/
  GpioPlatformReset    = 0x05,
  /**
  Deep Sleep Well Reset (DSW_PWROK)
    GPP: not applicable
    GPD: PadRstCfg = 00b = "Powergood"
  Pad settings will reset on:
  - G3
  Pad settings will not reset on:
  - S3/S4/S5 transition
  - Warm/Cold/Global reset
  - DeepSx transition
  **/
  GpioDswReset         = 0x07
} GPIO_RESET_CONFIG;

/**
  GPIO Electrical Configuration
  Set GPIO termination and Pad Tolerance (applicable only for some pads)
  Field from GpioTermNone to GpioTermNative can be OR'ed with GpioTolerance1v8.
**/
typedef enum {
  GpioTermDefault          = 0x0,  ///< Leave termination setting unmodified
  GpioTermNone             = 0x1,  ///< none
  GpioTermWpd5K            = 0x5,  ///< 5kOhm weak pull-down
  GpioTermWpd20K           = 0x9,  ///< 20kOhm weak pull-down
  GpioTermWpu1K            = 0x13, ///< 1kOhm weak pull-up
  GpioTermWpu2K            = 0x17, ///< 2kOhm weak pull-up
  GpioTermWpu5K            = 0x15, ///< 5kOhm weak pull-up
  GpioTermWpu20K           = 0x19, ///< 20kOhm weak pull-up
  GpioTermWpu1K2K          = 0x1B, ///< 1kOhm & 2kOhm weak pull-up
  /**
  Native function controls pads termination
  This setting is applicable only to some native modes.
  Please check EDS to determine which native functionality
  can control pads termination
  **/
  GpioTermNative     = 0x1F,
  GpioNoTolerance1v8 = (0x1 << 5),   ///< Disable 1.8V pad tolerance
  GpioTolerance1v8   = (0x3 << 5)    ///< Enable 1.8V pad tolerance
} GPIO_ELECTRICAL_CONFIG;

#define B_GPIO_ELECTRICAL_CONFIG_TERMINATION_MASK    0x1F   ///< Mask for GPIO_ELECTRICAL_CONFIG for termination value
#define B_GPIO_ELECTRICAL_CONFIG_1V8_TOLERANCE_MASK  0x60   ///< Mask for GPIO_ELECTRICAL_CONFIG for 1v8 tolerance setting

/**
  GPIO LockConfiguration
  Set GPIO configuration lock and output state lock.
  GpioLockPadConfig and GpioLockOutputState can be OR'ed.
  Lock settings reset is in Powergood domain. Care must be taken when using this setting
  as fields it locks may be reset by a different signal and can be controllable
  by what is in GPIO_RESET_CONFIG (PADCFG_DW0.PadRstCfg). GPIO library provides
  functions which allow to unlock a GPIO pad.
**/
typedef enum {
  GpioLockDefault          = 0x0,  ///< Leave lock setting unmodified
  GpioPadConfigLock        = 0x3,  ///< Lock Pad Configuration
  GpioOutputStateLock      = 0x5   ///< Lock GPIO pad output value
} GPIO_LOCK_CONFIG;

#define B_GPIO_LOCK_CONFIG_PAD_CONF_LOCK_MASK  0x3  ///< Mask for GPIO_LOCK_CONFIG for Pad Configuration Lock
#define B_GPIO_LOCK_CONFIG_OUTPUT_LOCK_MASK    0x5  ///< Mask for GPIO_LOCK_CONFIG for Pad Output Lock

/**
  Other GPIO Configuration
  GPIO_OTHER_CONFIG is used for less often settings and for future extensions
  Supported settings:
   - RX raw override to '1' - allows to override input value to '1'
      This setting is applicable only if in input mode (both in GPIO and native usage).
      The override takes place at the internal pad state directly from buffer and before the RXINV.
**/
typedef enum {
  GpioRxRaw1Default           = 0x0,  ///< Use default input override value
  GpioRxRaw1Dis               = 0x1,  ///< Don't override input
  GpioRxRaw1En                = 0x3   ///< Override input to '1'
} GPIO_OTHER_CONFIG;

#define B_GPIO_OTHER_CONFIG_RXRAW_MASK  0x3  ///< Mask for GPIO_OTHER_CONFIG for RxRaw1 setting

#pragma pack(pop)

#endif //_GPIO_CONFIG_H_
