//+------------------------------------------------------------------+
//|                                             CashPrinter_EA.mq5   |
//|                       CashPrinter - XAUUSD MT5 Expert Advisor    |
//+------------------------------------------------------------------+
#property strict
#property version   "0.100"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// GENERAL
//==================================================================
input group "GENERAL"
input ulong InpMagic = 5487757;
input bool InpAllowTrading = true;
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M5;

//==================================================================
// RISK
//==================================================================
input group "RISK"
input bool InpUseRiskSizing = true;
input double InpRiskPercent = 1.0;
input double InpFixedLot = 0.01;
input double InpHardMaxRiskPercent = 5.0;

//==================================================================
// STOP LOSS
//==================================================================
input group "STOP LOSS"
input bool InpStructureSL = true;
input int InpSwingLookback = 20;
input int InpSLBufferPoints = 50;
input int InpMaxSLPoints = 0;

//==================================================================
// TAKE PROFIT
//==================================================================
input group "TAKE PROFIT"
input double InpTP1_R = 1.0;
input double InpTP2_R = 2.0;
input double InpTP1ClosePercent = 50.0;

//==================================================================
// TRAILING
//==================================================================
input group "TRAILING"
input bool InpTrailingEnabled = true;
input double InpTrailStartR = 1.0;
input double InpTrailDistanceR = 0.5;

//==================================================================
// PROTECTION
//==================================================================
input group "TRADE PROTECTION"
input double InpDailyLossLimitPercent = 3.0;
input int InpMaxTradesPerDay = 3;
input int InpMaxOpenPositions = 1;
input int InpMaxSpreadPoints = 60;

//==================================================================
// SESSIONS
//==================================================================
input group "SESSIONS"
input bool InpLondonSession = true;
input int InpLondonStartHour = 8;
input int InpLondonEndHour = 12;

input bool InpNewYorkSession = true;
input int InpNewYorkStartHour = 13;
input int InpNewYorkEndHour = 18;

//==================================================================
// NEWS
//==================================================================
input group "NEWS FILTER"
input bool InpNewsBlockEnabled = true;

//==================================================================
// GLOBAL VARIABLES
//==================================================================
string g_symbol;

double g_point;
double g_tickSize;
double g_tickValue;

double g_minLot;
double g_maxLot;
double g_lotStep;

int g_digits;

datetime g_lastBar = 0;

//==================================================================
// INITIALIZATION
//==================================================================
int OnInit()
{
   g_symbol = _Symbol;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("CashPrinter: Could not select symbol.");
      return INIT_FAILED;
   }

   LoadBrokerSpecification();

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(g_symbol);

   Print("========================================");
   Print("CashPrinter EA initialized");
   Print("Symbol: ", g_symbol);
   Print("Digits: ", g_digits);
   Print("Point: ", g_point);
   Print("Tick Size: ", g_tickSize);
   Print("Tick Value: ", g_tickValue);
   Print("Min Lot: ", g_minLot);
   Print("Max Lot: ", g_maxLot);
   Print("Lot Step: ", g_lotStep);
   Print("========================================");

   return INIT_SUCCEEDED;
}

//==================================================================
// MAIN LOOP
//==================================================================
void OnTick()
{
   // Manage existing positions first
   ManageOpenPositions();

   if(!InpAllowTrading)
      return;

   // Only evaluate once per new signal candle
   if(!IsNewBar())
      return;

   // Safety checks
   if(!PreTradeChecks())
      return;

   // Strategy signal
   int signal = GetSignal();

   // 0 = no trade
   if(signal == 0)
      return;

   double sl = 0.0;

   if(!CalculateStructureSL(signal, sl))
   {
      Print("CashPrinter: No valid structural SL.");
      return;
   }

   double entry;

   if(signal > 0)
      entry = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   else
      entry = SymbolInfoDouble(g_symbol, SYMBOL_BID);

   if(!ValidateStopDistance(signal, entry, sl))
      return;

   double riskDistance = MathAbs(entry - sl);

   // Prevent excessively wide SL
   if(InpMaxSLPoints > 0)
   {
      if(riskDistance / g_point > InpMaxSLPoints)
      {
         Print("CashPrinter: SL too wide. Trade skipped.");
         return;
      }
   }

   double lot = CalculateLotSize(riskDistance);

   if(lot <= 0)
      return;

   OpenTrade(signal, lot, entry, sl);
}

//==================================================================
// BROKER DETECTION
//==================================================================
void LoadBrokerSpecification()
{
   g_digits = (int)SymbolInfoInteger(
      g_symbol,
      SYMBOL_DIGITS
   );

   g_point = SymbolInfoDouble(
      g_symbol,
      SYMBOL_POINT
   );

   g_tickSize = SymbolInfoDouble(
      g_symbol,
      SYMBOL_TRADE_TICK_SIZE
   );

   g_tickValue = SymbolInfoDouble(
      g_symbol,
      SYMBOL_TRADE_TICK_VALUE
   );

   g_minLot = SymbolInfoDouble(
      g_symbol,
      SYMBOL_VOLUME_MIN
   );

   g_maxLot = SymbolInfoDouble(
      g_symbol,
      SYMBOL_VOLUME_MAX
   );

   g_lotStep = SymbolInfoDouble(
      g_symbol,
      SYMBOL_VOLUME_STEP
   );
}

//==================================================================
// SAFETY CHECKS
//==================================================================
bool PreTradeChecks()
{
   // Session
   if(!IsTradingSession())
      return false;

   // Spread
   if(GetSpreadPoints() > InpMaxSpreadPoints)
      return false;

   // Existing positions
   if(CountCashPrinterPositions() >= InpMaxOpenPositions)
      return false;

   // Daily trade limit
   if(GetTodayTradeCount() >= InpMaxTradesPerDay)
      return false;

   // Daily loss protection
   if(IsDailyLossLimitReached())
      return false;

   // Terminal trading permission
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   // News filter
   if(IsNewsBlackout())
      return false;

   return true;
}

//==================================================================
// SPREAD
//==================================================================
double GetSpreadPoints()
{
   double ask = SymbolInfoDouble(
      g_symbol,
      SYMBOL_ASK
   );

   double bid = SymbolInfoDouble(
      g_symbol,
      SYMBOL_BID
   );

   return (ask - bid) / g_point;
}

//==================================================================
// SESSION
//==================================================================
bool IsTradingSession()
{
   MqlDateTime t;

   TimeToStruct(
      TimeCurrent(),
      t
   );

   bool london =
      InpLondonSession &&
      HourInWindow(
         t.hour,
         InpLondonStartHour,
         InpLondonEndHour
      );

   bool newYork =
      InpNewYorkSession &&
      HourInWindow(
         t.hour,
         InpNewYorkStartHour,
         InpNewYorkEndHour
      );

   return london || newYork;
}

bool HourInWindow(
   int hour,
   int startHour,
   int endHour
)
{
   if(startHour < endHour)
      return hour >= startHour &&
             hour < endHour;

   return hour >= startHour ||
          hour < endHour;
}

//==================================================================
// NEWS PLACEHOLDER
//==================================================================
bool IsNewsBlackout()
{
   /*
      Production version will use the MT5 economic calendar
      instead of a fixed clock window.

      For now this returns false.
   */

   return false;
}

//==================================================================
// NEW BAR
//==================================================================
bool IsNewBar()
{
   datetime currentBar =
      iTime(
         g_symbol,
         InpSignalTF,
         0
      );

   if(currentBar == 0)
      return false;

   if(currentBar == g_lastBar)
      return false;

   g_lastBar = currentBar;

   return true;
}

//==================================================================
// STRUCTURE STOP LOSS
//==================================================================
bool CalculateStructureSL(
   int signal,
   double &sl
)
{
   if(!InpStructureSL)
      return false;

   if(InpSwingLookback < 3)
      return false;

   int shift;

   if(signal > 0)
   {
      shift = iLowest(
         g_symbol,
         InpSignalTF,
         MODE_LOW,
         InpSwingLookback,
         1
      );
   }
   else
   {
      shift = iHighest(
         g_symbol,
         InpSignalTF,
         MODE_HIGH,
         InpSwingLookback,
         1
      );
   }

   if(shift < 0)
      return false;

   double swing;

   if(signal > 0)
   {
      swing = iLow(
         g_symbol,
         InpSignalTF,
         shift
      );

      sl =
         swing -
         InpSLBufferPoints * g_point;
   }
   else
   {
      swing = iHigh(
         g_symbol,
         InpSignalTF,
         shift
      );

      sl =
         swing +
         InpSLBufferPoints * g_point;
   }

   sl = NormalizeDouble(
      sl,
      g_digits
   );

   return sl > 0;
}

//==================================================================
// STOP VALIDATION
//==================================================================
bool ValidateStopDistance(
   int signal,
   double entry,
   double sl
)
{
   long stopsLevel =
      SymbolInfoInteger(
         g_symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double minimumDistance =
      stopsLevel * g_point;

   if(signal > 0)
   {
      if(sl >= entry)
         return false;

      if(entry - sl < minimumDistance)
         return false;
   }
   else
   {
      if(sl <= entry)
         return false;

      if(sl - entry < minimumDistance)
         return false;
   }

   return true;
}

//==================================================================
// LOT CALCULATION
//==================================================================
double CalculateLotSize(
   double riskDistance
)
{
   double lot = InpFixedLot;

   if(InpUseRiskSizing)
   {
      double riskPercent =
         MathMin(
            InpRiskPercent,
            InpHardMaxRiskPercent
         );

      double equity =
         AccountInfoDouble(
            ACCOUNT_EQUITY
         );

      double moneyRisk =
         equity *
         riskPercent /
         100.0;

      if(
         g_tickSize <= 0 ||
         g_tickValue <= 0 ||
         riskDistance <= 0
      )
      {
         return 0;
      }

      double lossPerLot =
         (riskDistance / g_tickSize) *
         g_tickValue;

      if(lossPerLot <= 0)
         return 0;

      lot =
         moneyRisk /
         lossPerLot;
   }

   return NormalizeVolume(lot);
}

//==================================================================
// VOLUME NORMALIZATION
//==================================================================
double NormalizeVolume(
   double volume
)
{
   if(g_lotStep <= 0)
      return 0;

   volume =
      MathMax(
         volume,
         g_minLot
      );

   volume =
      MathMin(
         volume,
         g_maxLot
      );

   double steps =
      MathFloor(
         volume / g_lotStep
      );

   volume =
      steps *
      g_lotStep;

   if(volume < g_minLot)
      volume = g_minLot;

   return NormalizeDouble(
      volume,
      VolumeDigits(g_lotStep)
   );
}

int VolumeDigits(
   double step
)
{
   int digits = 0;

   while(
      step < 1.0 &&
      digits < 8
   )
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}

//==================================================================
// OPEN TRADE
//==================================================================
void OpenTrade(
   int signal,
   double lot,
   double entry,
   double sl
)
{
   double risk =
      MathAbs(
         entry - sl
      );

   double tp1;
   double tp2;

   if(signal > 0)
   {
      tp1 =
         entry +
         risk * InpTP1_R;

      tp2 =
         entry +
         risk * InpTP2_R;
   }
   else
   {
      tp1 =
         entry -
         risk * InpTP1_R;

      tp2 =
         entry -
         risk * InpTP2_R;
   }

   tp1 =
      NormalizeDouble(
         tp1,
         g_digits
      );

   tp2 =
      NormalizeDouble(
         tp2,
         g_digits
      );

   bool result;

   if(signal > 0)
   {
      result =
         trade.Buy(
            lot,
            g_symbol,
            0,
            sl,
            tp2,
            "CashPrinter BUY"
         );
   }
   else
   {
      result =
         trade.Sell(
            lot,
            g_symbol,
            0,
            sl,
            tp2,
            "CashPrinter SELL"
         );
   }

   if(!result)
   {
      Print(
         "CashPrinter order failed: ",
         trade.ResultRetcodeDescription()
      );

      return;
   }

   Print(
      "CashPrinter trade opened."
   );
}

//==================================================================
// POSITION MANAGEMENT
//==================================================================
void ManageOpenPositions()
{
   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(
         PositionGetString(
            POSITION_SYMBOL
         ) != g_symbol
      )
         continue;

      if(
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) != InpMagic
      )
         continue;

      ManagePosition(ticket);
   }
}

//==================================================================
// TRAILING
//==================================================================
void ManagePosition(
   ulong ticket
)
{
   double openPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double sl =
      PositionGetDouble(
         POSITION_SL
      );

   double tp =
      PositionGetDouble(
         POSITION_TP
      );

   long type =
      PositionGetInteger(
         POSITION_TYPE
      );

   double current;

   if(type == POSITION_TYPE_BUY)
   {
      current =
         SymbolInfoDouble(
            g_symbol,
            SYMBOL_BID
         );
   }
   else
   {
      current =
         SymbolInfoDouble(
            g_symbol,
            SYMBOL_ASK
         );
   }

   double initialRisk =
      MathAbs(
         openPrice - sl
      );

   if(initialRisk <= 0)
      return;

   double profitDistance;

   if(type == POSITION_TYPE_BUY)
   {
      profitDistance =
         current -
         openPrice;
   }
   else
   {
      profitDistance =
         openPrice -
         current;
   }

   double profitR =
      profitDistance /
      initialRisk;

   if(
      InpTrailingEnabled &&
      profitR >= InpTrailStartR
   )
   {
      double newSL;

      if(type == POSITION_TYPE_BUY)
      {
         newSL =
            current -
            initialRisk *
            InpTrailDistanceR;
      }
      else
      {
         newSL =
            current +
            initialRisk *
            InpTrailDistanceR;
      }

      newSL =
         NormalizeDouble(
            newSL,
            g_digits
         );

      bool improves =
         (
            type == POSITION_TYPE_BUY &&
            newSL > sl
         )
         ||
         (
            type == POSITION_TYPE_SELL &&
            newSL < sl
         );

      if(improves)
      {
         trade.PositionModify(
            ticket,
            newSL,
            tp
         );
      }
   }
}

//==================================================================
// COUNT OPEN POSITIONS
//==================================================================
int CountCashPrinterPositions()
{
   int count = 0;

   for(
      int i = 0;
      i < PositionsTotal();
      i++
   )
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(
         PositionGetString(
            POSITION_SYMBOL
         ) == g_symbol &&
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) == InpMagic
      )
      {
         count++;
      }
   }

   return count;
}

//==================================================================
// TODAY'S TRADE COUNT
//==================================================================
int GetTodayTradeCount()
{
   datetime dayStart =
      StringToTime(
         TimeToString(
            TimeCurrent(),
            TIME_DATE
         )
      );

   if(
      !HistorySelect(
         dayStart,
         TimeCurrent()
      )
   )
   {
      return 0;
   }

   int count = 0;

   int total =
      HistoryDealsTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong deal =
         HistoryDealGetTicket(i);

      if(deal == 0)
         continue;

      if(
         HistoryDealGetString(
            deal,
            DEAL_SYMBOL
         ) != g_symbol
      )
      {
         continue;
      }

      if(
         (ulong)HistoryDealGetInteger(
            deal,
            DEAL_MAGIC
         ) != InpMagic
      )
      {
         continue;
      }

      if(
         HistoryDealGetInteger(
            deal,
            DEAL_ENTRY
         ) == DEAL_ENTRY_IN
      )
      {
         count++;
      }
   }

   return count;
}

//==================================================================
// DAILY LOSS PROTECTION
//==================================================================
bool IsDailyLossLimitReached()
{
   if(
      InpDailyLossLimitPercent <= 0
   )
   {
      return false;
   }

   datetime dayStart =
      StringToTime(
         TimeToString(
            TimeCurrent(),
            TIME_DATE
         )
      );

   if(
      !HistorySelect(
         dayStart,
         TimeCurrent()
      )
   )
   {
      return false;
   }

   double pnl = 0;

   int total =
      HistoryDealsTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong deal =
         HistoryDealGetTicket(i);

      if(deal == 0)
         continue;

      if(
         HistoryDealGetString(
            deal,
            DEAL_SYMBOL
         ) != g_symbol
      )
      {
         continue;
      }

      if(
         (ulong)HistoryDealGetInteger(
            deal,
            DEAL_MAGIC
         ) != InpMagic
      )
      {
         continue;
      }

      pnl +=
         HistoryDealGetDouble(
            deal,
            DEAL_PROFIT
         );

      pnl +=
         HistoryDealGetDouble(
            deal,
            DEAL_SWAP
         );

      pnl +=
         HistoryDealGetDouble(
            deal,
            DEAL_COMMISSION
         );
   }

   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   double allowedLoss =
      equity *
      InpDailyLossLimitPercent /
      100.0;

   return pnl <= -allowedLoss;
}

//==================================================================
// STRATEGY ENGINE — NEXT BUILD
//==================================================================
int GetSignal()
{
   /*
      0  = NO TRADE
      1  = BUY
     -1  = SELL

      We deliberately leave this at zero until the actual
      CashPrinter entry algorithm is implemented and tested.

      This prevents the foundation from placing random trades.
   */

   return 0;
}
//+------------------------------------------------------------------+