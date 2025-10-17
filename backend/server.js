// Only load dotenv in development
if (process.env.NODE_ENV !== 'production') {
  require('dotenv').config();
}

const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');

// Initialize Stripe with error handling
let stripe;
try {
  if (!process.env.STRIPE_SECRET_KEY) {
    console.error('❌ STRIPE_SECRET_KEY not found in environment variables!');
  } else {
    stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
    console.log('✅ Stripe initialized successfully');
  }
} catch (error) {
  console.error('❌ Error initializing Stripe:', error.message);
}

const app = express();
const PORT = process.env.PORT || 8080;

// Middleware
app.use(cors());
app.use(bodyParser.json());

// For Stripe webhooks - needs raw body
app.use('/webhook', bodyParser.raw({ type: 'application/json' }));

// Health check
app.get('/', (req, res) => {
  res.json({ status: 'CrowdFuel Backend Running', timestamp: new Date().toISOString() });
});

/**
 * Create Stripe Connect account for a band
 * POST /create-connect-account
 * Body: { bandId, email, country }
 * 
 * Note: This endpoint creates the Stripe account but does NOT save to Firestore
 * The iOS app is responsible for saving the accountId after successful onboarding
 */
app.post('/create-connect-account', async (req, res) => {
  try {
    const { bandId, email, country = 'US' } = req.body;

    if (!bandId || !email) {
      return res.status(400).json({ error: 'bandId and email are required' });
    }

    // Create Stripe Connect Express account
    const account = await stripe.accounts.create({
      type: 'express',
      country: country,
      email: email,
      capabilities: {
        card_payments: { requested: true },
        transfers: { requested: true },
      },
      business_type: 'individual',
    });

    console.log(`✅ Created Stripe account ${account.id} for band ${bandId}`);

    // Create account link for onboarding
    const accountLink = await stripe.accountLinks.create({
      account: account.id,
      refresh_url: `https://crowdfuel-86c2b.web.app/connect/refresh.html`,
      return_url: `https://crowdfuel-86c2b.web.app/connect/return.html?accountId=${account.id}&bandId=${bandId}`,
      type: 'account_onboarding',
    });

    res.json({
      accountId: account.id,
      onboardingUrl: accountLink.url,
    });
  } catch (error) {
    console.error('Error creating Connect account:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * Get Stripe Connect account status
 * POST /connect-account-status
 * Body: { accountId }
 */
app.post('/connect-account-status', async (req, res) => {
  try {
    const { accountId } = req.body;

    if (!accountId) {
      return res.status(400).json({ error: 'accountId is required' });
    }

    const account = await stripe.accounts.retrieve(accountId);

    res.json({
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
    });
  } catch (error) {
    console.error('Error checking account status:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * Create payment intent with 5% platform fee
 * POST /create-payment-intent
 * Body: { amount, currency, bandStripeAccountId, description }
 */
app.post('/create-payment-intent', async (req, res) => {
  try {
    const { amount, currency = 'usd', bandStripeAccountId, description } = req.body;

    if (!amount || !bandStripeAccountId) {
      return res.status(400).json({ error: 'amount and bandStripeAccountId are required' });
    }

    // Calculate platform fee (5%)
    const platformFee = Math.round(amount * 0.05);

    // Create payment intent with application fee
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amount,
      currency: currency,
      application_fee_amount: platformFee,
      transfer_data: {
        destination: bandStripeAccountId,
      },
      description: description,
      automatic_payment_methods: {
        enabled: true,
      },
      metadata: {
        bandStripeAccountId: bandStripeAccountId,
        platformFee: platformFee,
      },
    });

    res.json({
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      platformFee: platformFee,
      bandAmount: amount - platformFee,
    });
  } catch (error) {
    console.error('Error creating payment intent:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * Get payout dashboard link for band
 * POST /payout-dashboard-link
 * Body: { accountId }
 */
app.post('/payout-dashboard-link', async (req, res) => {
  try {
    const { accountId } = req.body;

    if (!accountId) {
      return res.status(400).json({ error: 'accountId is required' });
    }

    const loginLink = await stripe.accounts.createLoginLink(accountId);

    res.json({
      url: loginLink.url,
    });
  } catch (error) {
    console.error('Error creating login link:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * Stripe webhook handler
 * POST /webhook
 */
app.post('/webhook', async (req, res) => {
  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  let event;

  try {
    event = stripe.webhooks.constructEvent(req.body, sig, webhookSecret);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  // Handle the event
  switch (event.type) {
    case 'payment_intent.succeeded':
      const paymentIntent = event.data.object;
      console.log('PaymentIntent succeeded:', paymentIntent.id);
      console.log('Platform fee:', paymentIntent.application_fee_amount);
      console.log('Band account:', paymentIntent.transfer_data?.destination);
      break;

    case 'payment_intent.payment_failed':
      const failedPayment = event.data.object;
      console.log('PaymentIntent failed:', failedPayment.id);
      break;

    case 'account.updated':
      const account = event.data.object;
      console.log('Account updated:', account.id);
      console.log('Charges enabled:', account.charges_enabled);
      console.log('Payouts enabled:', account.payouts_enabled);
      break;

    case 'transfer.created':
      const transfer = event.data.object;
      console.log('Transfer created:', transfer.id);
      console.log('Amount:', transfer.amount);
      console.log('Destination:', transfer.destination);
      break;

    case 'payout.paid':
      const payout = event.data.object;
      console.log('Payout completed:', payout.id);
      console.log('Amount:', payout.amount);
      break;

    default:
      console.log(`Unhandled event type ${event.type}`);
  }

  res.json({ received: true });
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 CrowdFuel Backend running on port ${PORT}`);
  console.log(`📝 Environment: ${process.env.NODE_ENV || 'development'}`);
  console.log(`📝 Endpoints:`);
  console.log(`   GET  /`);
  console.log(`   POST /create-connect-account`);
  console.log(`   POST /connect-account-status`);
  console.log(`   POST /create-payment-intent`);
  console.log(`   POST /payout-dashboard-link`);
  console.log(`   POST /webhook`);
  console.log(`\n🔑 Environment variables:`);
  console.log(`   STRIPE_SECRET_KEY: ${process.env.STRIPE_SECRET_KEY ? '✅ Set' : '❌ Missing'}`);
  console.log(`   STRIPE_WEBHOOK_SECRET: ${process.env.STRIPE_WEBHOOK_SECRET ? '✅ Set' : '❌ Missing'}`);
  console.log(`   PORT: ${PORT}`);
  console.log(`   NODE_ENV: ${process.env.NODE_ENV || 'not set'}`);
}).on('error', (err) => {
  console.error('❌ Server failed to start:', err.message);
  process.exit(1);
});

module.exports = app;

